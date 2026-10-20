// Node.js reference harness for benchmarking against the original JavaScript
// implementation (Petschko's RPG-Maker-MV-Decrypter, scripts/Decrypter.js).
//
// The original is a browser app: it reads files with FileReader and saves
// them via Blob/ZIP. This harness loads the *unmodified* Decrypter.js into
// Node and calls its own decrypt() (fake-header check, slice, XOR) per file,
// replacing only the browser I/O with node:fs. Key detection mirrors the
// original: JSON.parse of System.json -> encryptionKey.
//
//   node bench/node_original.js <game_dir> --output <out_dir>
//        [--decrypter path/to/Decrypter.js] [--async [--concurrency N]]
//
// --async uses fs.promises with N files in flight (default 64) — a
// best-effort Node port; the default is the straightforward synchronous one.
'use strict';
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const vm = require('node:vm');

const args = process.argv.slice(2);
const opt = (name, def) => {
	const i = args.indexOf(name);
	if (i < 0) return def;
	const v = args[i + 1];
	args.splice(i, 2);
	return v;
};
const flag = (name) => {
	const i = args.indexOf(name);
	if (i < 0) return false;
	args.splice(i, 1);
	return true;
};
const output = opt('--output');
const decrypterPath = opt('--decrypter', path.join(__dirname, '..', '..', 'RPG-Maker-MV-Decrypter-master', 'scripts', 'Decrypter.js'));
const concurrency = Number(opt('--concurrency', '64'));
const useAsync = flag('--async');
const input = args[0];
if (!input || !output) {
	console.error('usage: node node_original.js <game_dir> --output <out_dir> [--async]');
	process.exit(2);
}

// Load the original implementation verbatim. It only touches browser globals
// on error paths (html/lang/ErrorException) and in modifyFile (FileReader),
// which this harness does not call.
const sandbox = {
	window: {},
	lang: { strings: {} },
	html: (s) => String(s),
	ErrorException: function (msg, code) { this.message = msg; this.code = code; },
	console,
};
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(decrypterPath, 'utf8'), sandbox, { filename: decrypterPath });
const Decrypter = sandbox.Decrypter;

const encryptedExt = { rpgmvp: 'png', png_: 'png', rpgmvm: 'm4a', m4a_: 'm4a', rpgmvo: 'ogg', ogg_: 'ogg' };

function walk(dir, rel, out) {
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const r = rel ? rel + path.sep + e.name : e.name;
		if (e.isDirectory()) walk(path.join(dir, e.name), r, out);
		else if (e.isFile()) out.push(r);
	}
	return out;
}

function findKey(root) {
	for (const p of ['www/data/System.json', 'data/System.json']) {
		try {
			return JSON.parse(fs.readFileSync(path.join(root, p), 'utf8')).encryptionKey;
		} catch { /* try next */ }
	}
	return null;
}

const toArrayBuffer = (buf) => buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);

function plan() {
	const key = findKey(input);
	if (!key) throw new Error('no key in System.json');
	const decrypter = new Decrypter(key);
	const jobs = [];
	const dirs = new Set();
	for (const rel of walk(input, '', [])) {
		const ext = path.extname(rel).slice(1).toLowerCase();
		const outExt = encryptedExt[ext];
		if (!outExt) continue;
		const outRel = rel.slice(0, rel.length - ext.length) + outExt;
		jobs.push([rel, outRel]);
		dirs.add(path.dirname(outRel));
	}
	for (const d of dirs) fs.mkdirSync(path.join(output, d), { recursive: true });
	return { decrypter, jobs };
}

function runSync() {
	const { decrypter, jobs } = plan();
	let failed = 0;
	for (const [rel, outRel] of jobs) {
		try {
			const out = decrypter.decrypt(toArrayBuffer(fs.readFileSync(path.join(input, rel))));
			fs.writeFileSync(path.join(output, outRel), new Uint8Array(out), { flag: 'wx' });
		} catch { failed++; }
	}
	return [jobs.length, failed];
}

async function runAsync() {
	const { decrypter, jobs } = plan();
	let next = 0;
	let failed = 0;
	async function lane() {
		while (next < jobs.length) {
			const [rel, outRel] = jobs[next++];
			try {
				const out = decrypter.decrypt(toArrayBuffer(await fsp.readFile(path.join(input, rel))));
				await fsp.writeFile(path.join(output, outRel), new Uint8Array(out), { flag: 'wx' });
			} catch { failed++; }
		}
	}
	await Promise.all(Array.from({ length: concurrency }, lane));
	return [jobs.length, failed];
}

(async () => {
	const t0 = process.hrtime.bigint();
	const [n, failed] = useAsync ? await runAsync() : runSync();
	const ms = Number(process.hrtime.bigint() - t0) / 1e6;
	console.error(`${n - failed} files processed, ${failed} failed (${ms.toFixed(0)} ms)`);
	process.exit(failed ? 1 : 0);
})();
