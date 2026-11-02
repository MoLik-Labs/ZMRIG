// The instruction levels the image is built for. `x86-64-v3` needs AVX2, which
// is every desktop x86 CPU since about 2015; `v2` runs on anything since
// Nehalem. Both are shipped for every release.

'use strict';

const ARCHES = [
  { slug: 'v3', name: 'x86-64-v3', label: 'x86-64-v3', note: 'AVX2 — most CPUs since 2015', rank: 3 },
  { slug: 'v2', name: 'x86-64-v2', label: 'x86-64-v2', note: 'anything since Nehalem', rank: 2 },
];

module.exports = { ARCHES };
