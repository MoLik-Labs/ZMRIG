// Telegram, long polling.
//
// Long polling and not a webhook on purpose: a webhook needs a public HTTPS URL
// with a certificate, and a self-hosted fleet on a free host can be restarted,
// moved or tunnelled without telling Telegram anything. `getUpdates` with a
// 25-second wait costs one idle connection and keeps working behind NAT.

'use strict';

const API = 'https://api.telegram.org';

/** Telegram's accent is HTML, and it needs three characters escaped. The
 *  command layer writes Discord-flavoured `**bold**` and backticks, so this is
 *  the only place that knows both. */
function render(text) {
  let body = String(text)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');

  body = body.replace(/```([\s\S]*?)```/g, (_, code) => `<pre>${code.replace(/^\n|\n$/g, '')}</pre>`);
  body = body.replace(/`([^`\n]+)`/g, '<code>$1</code>');
  body = body.replace(/\*\*([^*\n]+)\*\*/g, '<b>$1</b>');
  return body;
}

/** 4096 is the hard limit; leave room for the tags added above. */
function chunks(text, limit = 3500) {
  const body = String(text);
  if (body.length <= limit) return [body];

  const out = [];
  let rest = body;
  while (rest.length > limit) {
    let cut = rest.lastIndexOf('\n\n', limit);
    if (cut < limit / 2) cut = rest.lastIndexOf('\n', limit);
    if (cut < limit / 2) cut = limit;
    out.push(rest.slice(0, cut));
    rest = rest.slice(cut).replace(/^\n+/, '');
  }
  if (rest) out.push(rest);
  return out;
}

function keyboard(rows) {
  if (!rows || rows.length === 0) return undefined;
  return {
    inline_keyboard: rows.map((row) =>
      row.map((button) => ({ text: button.text, callback_data: button.data.slice(0, 64) })),
    ),
  };
}

class Telegram {
  constructor({ token, log = () => {} }) {
    this.token = token;
    this.log = log;
    this.offset = 0;
    this.stopped = false;
    this.botId = Number(String(token).split(':')[0]) || null;
    this.failures = 0;
  }

  async api(method, payload = {}, timeout = 30000) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeout);
    try {
      const response = await fetch(`${API}/bot${this.token}/${method}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(payload),
        signal: controller.signal,
      });
      const body = await response.json().catch(() => ({}));
      if (!body.ok) {
        const error = new Error(body.description || `HTTP ${response.status}`);
        error.code = body.error_code;
        throw error;
      }
      return body.result;
    } finally {
      clearTimeout(timer);
    }
  }

  async send(chatId, text, rows) {
    const parts = chunks(text);
    let first = null;
    for (let index = 0; index < parts.length; index += 1) {
      const result = await this.api('sendMessage', {
        chat_id: chatId,
        text: render(parts[index]),
        parse_mode: 'HTML',
        link_preview_options: { is_disabled: true },
        reply_markup: index === parts.length - 1 ? keyboard(rows) : undefined,
      });
      first = first || result;
    }
    return first;
  }

  async edit(chatId, messageId, text, rows) {
    try {
      return await this.api('editMessageText', {
        chat_id: chatId,
        message_id: messageId,
        text: render(text),
        parse_mode: 'HTML',
        link_preview_options: { is_disabled: true },
        reply_markup: keyboard(rows),
      });
    } catch (error) {
      // "message is not modified" is the normal answer to a refresh that found
      // nothing new, and it is not a failure.
      if (/not modified/i.test(error.message)) return null;
      throw error;
    }
  }

  async answer(callbackId, text) {
    try {
      await this.api('answerCallbackQuery', { callback_query_id: callbackId, text: text ? String(text).slice(0, 190) : undefined });
    } catch (error) {
      this.log(`answerCallbackQuery: ${error.message}`);
    }
  }

  async identity() {
    const me = await this.api('getMe');
    this.botId = me.id;
    return me;
  }

  /** One message in, one reply out. Errors are caught per message: one bad
   *  command must never stop the polling loop. */
  async handleUpdate(update, handlers) {
    if (update.callback_query) {
      const query = update.callback_query;
      const actor = actorFor(query.from, 'tg');
      await this.answer(query.id);
      try {
        const reply = handlers.onCallback({ data: query.data, actor });
        if (reply && reply.text) {
          await this.edit(query.message.chat.id, query.message.message_id, reply.text, reply.keyboard);
        }
      } catch (error) {
        this.log(`callback ${query.data}: ${error.stack || error.message}`);
      }
      return;
    }

    const message = update.message;
    if (!message || !message.text) return;
    const actor = actorFor(message.from, 'tg');
    try {
      const reply = handlers.onMessage({ text: message.text, actor, chatId: message.chat.id });
      if (reply && reply.text) await this.send(message.chat.id, reply.text, reply.keyboard);
    } catch (error) {
      this.log(`message: ${error.stack || error.message}`);
      await this.send(message.chat.id, '⚠️ internal error; the log has the details').catch(() => {});
    }
  }

  async start(handlers) {
    this.stopped = false;
    await this.identity().catch((error) => this.log(`getMe failed: ${error.message}`));

    while (!this.stopped) {
      try {
        const updates = await this.api(
          'getUpdates',
          { offset: this.offset, timeout: 25, allowed_updates: ['message', 'callback_query'] },
          40000,
        );
        this.failures = 0;
        for (const update of updates) {
          this.offset = Math.max(this.offset, update.update_id + 1);
          await this.handleUpdate(update, handlers);
        }
      } catch (error) {
        this.failures += 1;
        // A second instance polling the same token is the one error a restart
        // will not fix, so say what it is instead of printing it 500 times.
        if (error.code === 409) this.log('another process is polling this bot token; backing off');
        else this.log(`poll failed (${this.failures}): ${error.message}`);
        const wait = Math.min(30000, 1000 * 2 ** Math.min(this.failures, 5));
        await new Promise((resolve) => setTimeout(resolve, wait));
      }
    }
  }

  stop() {
    this.stopped = true;
  }
}

function actorFor(from, platform) {
  return {
    platform,
    id: String(from.id),
    key: `${platform}:${from.id}`,
    name: from.username || from.first_name || String(from.id),
    role: 'operator',
  };
}

module.exports = { Telegram, render, chunks, keyboard, actorFor };
