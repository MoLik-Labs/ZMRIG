// Discord, over the gateway.
//
// No dependency: Node 22 ships a WebSocket, and the gateway protocol is a
// handful of opcodes. What it buys over an HTTP-only bot is that the fleet can
// speak without being asked - a rig going offline at 03:00 has nobody typing at
// it - and that a slash-command registration step is not needed to use buttons.

'use strict';

const API = 'https://discord.com/api/v10';

// GUILDS | GUILD_MESSAGES | DIRECT_MESSAGES | MESSAGE_CONTENT
const INTENTS = 1 | 512 | 4096 | 32768;

class Discord {
  constructor({ token, log = () => {} }) {
    this.token = token;
    this.log = log;
    this.seq = null;
    this.session = null;
    this.ws = null;
    this.botId = null;
    this.stopped = false;
    this.failures = 0;
    this.heartbeatTimer = null;
    this.lastHeartbeatAck = true;
  }

  async rest(method, path, body) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 20000);
    try {
      const response = await fetch(`${API}${path}`, {
        method,
        headers: {
          authorization: `Bot ${this.token}`,
          'content-type': 'application/json',
          'user-agent': 'ZMRIGFleet (https://github.com/MoLik-Labs/ZMRIG, 6.37)',
        },
        body: body ? JSON.stringify(body) : undefined,
        signal: controller.signal,
      });
      if (response.status === 204) return null;
      const text = await response.text();
      const parsed = text ? JSON.parse(text) : null;
      if (!response.ok) {
        const error = new Error(`discord ${method} ${path}: ${response.status} ${text.slice(0, 200)}`);
        error.status = response.status;
        throw error;
      }
      return parsed;
    } finally {
      clearTimeout(timer);
    }
  }

  async identity() {
    const me = await this.rest('GET', '/users/@me');
    this.botId = me.id;
    return me;
  }

  components(rows) {
    if (!rows || rows.length === 0) return undefined;
    return rows.slice(0, 5).map((row) => ({
      type: 1,
      components: row.slice(0, 5).map((button) => ({
        type: 2,
        style: button.style || 2,
        label: button.text.slice(0, 80),
        custom_id: button.data.slice(0, 100),
      })),
    }));
  }

  /** 2000 characters is Discord's limit for a message; split on blank lines so a
   *  table stays in one piece. */
  chunks(text, limit = 1900) {
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

  async send(channelId, text, rows) {
    const parts = this.chunks(text);
    let first = null;
    for (let index = 0; index < parts.length; index += 1) {
      const result = await this.rest('POST', `/channels/${channelId}/messages`, {
        content: parts[index],
        components: index === parts.length - 1 ? this.components(rows) : undefined,
        allowed_mentions: { parse: [] },
      });
      first = first || result;
    }
    return first;
  }

  /** DMs need a channel first, and the channel id changes if the user ever
   *  deletes the conversation, so it is not cached across sends. */
  async dm(userId, text, rows) {
    const channel = await this.rest('POST', '/users/@me/channels', { recipient_id: userId });
    return this.send(channel.id, text, rows);
  }

  async webhook(interaction, text, rows) {
    const body = {
      type: 4,
      data: { content: this.chunks(text)[0], components: this.components(rows), allowed_mentions: { parse: [] } },
    };
    return this.rest('POST', `/interactions/${interaction.id}/${interaction.token}/callback`, body);
  }

  handleDispatch(payload, handlers) {
    if (payload.t === 'MESSAGE_CREATE') {
      const message = payload.d;
      if (!message || !message.content || (message.author && message.author.bot)) return;
      const mentioned = this.botId && Array.isArray(message.mentions)
        ? message.mentions.some((user) => user.id === this.botId)
        : false;
      if (!mentioned && !/^[!/]/.test(message.content)) return;

      const text = mentioned
        ? message.content.replace(new RegExp(`<@!?${this.botId}>`, 'g'), ' ').trim()
        : message.content;
      const actor = actorFor(message.author);
      try {
        const reply = handlers.onMessage({ text, actor, chatId: message.channel_id });
        if (reply && reply.text) this.send(message.channel_id, reply.text, reply.keyboard).catch((error) => this.log(error.message));
      } catch (error) {
        this.log(`message: ${error.stack || error.message}`);
      }
      return;
    }

    if (payload.t === 'INTERACTION_CREATE') {
      const interaction = payload.d;
      if (!interaction || interaction.type !== 3) return;
      const actor = actorFor(interaction.member ? interaction.member.user : interaction.user);
      try {
        const reply = handlers.onCallback({ data: interaction.data && interaction.data.custom_id, actor });
        if (reply && reply.text) this.webhook(interaction, reply.text, reply.keyboard).catch((error) => this.log(error.message));
      } catch (error) {
        this.log(`interaction: ${error.stack || error.message}`);
      }
    }
  }

  heartbeat(interval) {
    clearInterval(this.heartbeatTimer);
    this.heartbeatTimer = setInterval(() => {
      if (!this.ws || this.ws.readyState !== 1) return;
      if (!this.lastHeartbeatAck) {
        this.log('no heartbeat ack; reconnecting');
        this.ws.close(4000);
        return;
      }
      this.lastHeartbeatAck = false;
      this.ws.send(JSON.stringify({ op: 1, d: this.seq }));
    }, interval);
    if (this.heartbeatTimer.unref) this.heartbeatTimer.unref();
  }

  connect(url, handlers) {
    return new Promise((resolve) => {
      const socket = new WebSocket(`${url}/?v=10&encoding=json`);
      this.ws = socket;
      let interval = 41250;
      let identified = false;

      const identify = () => {
        identified = true;
        socket.send(
          JSON.stringify({
            op: 2,
            d: {
              token: this.token,
              intents: INTENTS,
              properties: { os: 'linux', browser: 'zmrig-fleet', device: 'zmrig-fleet' },
              presence: { status: 'online', activities: [{ name: 'the fleet', type: 3 }] },
            },
          }),
        );
      };

      socket.addEventListener('open', () => {
        this.failures = 0;
        resolve();
      });

      socket.addEventListener('message', (event) => {
        let payload;
        try {
          payload = JSON.parse(event.data);
        } catch (error) {
          return;
        }
        if (payload.s !== null && payload.s !== undefined) this.seq = payload.s;

        switch (payload.op) {
          case 10:
            interval = payload.d.heartbeat_interval;
            this.heartbeat(interval);
            if (this.session && this.seq !== null) {
              socket.send(JSON.stringify({ op: 6, d: { token: this.token, session_id: this.session, seq: this.seq } }));
              identified = true;
            } else {
              identify();
            }
            break;
          case 11:
            this.lastHeartbeatAck = true;
            break;
          case 1:
            socket.send(JSON.stringify({ op: 1, d: this.seq }));
            break;
          case 7:
            socket.close(4000);
            break;
          case 9:
            this.session = null;
            this.seq = null;
            identified = false;
            setTimeout(() => socket.readyState === 1 && identify(), 2000 + Math.random() * 3000);
            break;
          case 0:
            if (payload.t === 'READY') {
              this.session = payload.d.session_id;
              this.botId = payload.d.user && payload.d.user.id;
              this.log(`discord ready as ${payload.d.user ? payload.d.user.username : '?'}`);
            }
            if (payload.t === 'RESUMED') this.log('discord session resumed');
            this.handleDispatch(payload, handlers);
            break;
          default:
            break;
        }
        void identified;
      });

      socket.addEventListener('close', () => {
        clearInterval(this.heartbeatTimer);
        resolve();
      });

      socket.addEventListener('error', () => {
        // `close` follows, and the loop in start() reconnects with a backoff.
      });
    });
  }

  async start(handlers) {
    this.stopped = false;
    await this.identity().catch((error) => this.log(`identity: ${error.message}`));

    while (!this.stopped) {
      try {
        const gateway = this.session
          ? { url: 'wss://gateway.discord.gg' }
          : await this.rest('GET', '/gateway/bot');
        await this.connect(gateway.url, handlers);
      } catch (error) {
        this.failures += 1;
        this.log(`gateway: ${error.message}`);
      }

      if (this.stopped) break;
      const wait = Math.min(30000, 1000 * 2 ** Math.min(this.failures, 5));
      await new Promise((resolve) => setTimeout(resolve, wait));
    }
  }

  stop() {
    this.stopped = true;
    clearInterval(this.heartbeatTimer);
    if (this.ws) this.ws.close(1000);
  }
}

function actorFor(user) {
  const id = String(user.id);
  return {
    platform: 'dc',
    id,
    key: `dc:${id}`,
    name: user.username || id,
    role: 'operator',
  };
}

module.exports = { Discord, actorFor, INTENTS };
