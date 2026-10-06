const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const listeners = new Set();
let state = 'complete', page = {}, sent, contextClick, onMessage;
const tab = {id: 1, url: 'https://example.test/article', title: 'Article'};
const chrome = {
  runtime: {
    onInstalled: {addListener() {}},
    onMessage: {addListener(fn) {onMessage = fn;}},
    sendNativeMessage(host, payload, callback) {sent = payload; callback({ok: true});},
  },
  notifications: {create() {}},
  contextMenus: {create() {}, onClicked: {addListener(fn) {contextClick = fn;}}},
  tabs: {async query() {return [tab];}},
  scripting: {async executeScript() {return [{result: page}];}},
  downloads: {
    download(options, callback) {callback(7);},
    search(query, callback) {callback([{state, filename: '/tmp/paper.pdf', finalUrl: 'https://example.test/paper.pdf'}]);},
    onChanged: {addListener(fn) {listeners.add(fn);}, removeListener(fn) {listeners.delete(fn);}},
  },
};
const ctx = vm.createContext({chrome, URL, crypto: require('node:crypto').webcrypto, setTimeout, clearTimeout});
vm.runInContext(fs.readFileSync('chrome/zettypst-capture/background.js', 'utf8'), ctx);
const message = action => new Promise(resolve => onMessage({action}, {}, resolve));
(async () => {
  assert.equal((await message('ping')).ok, true);
  assert.equal(sent.action, 'ping');
  page = {selection: 'selected text'};
  await message('captureAuto');
  assert.equal(sent.action, 'capturePage');
  assert.equal(sent.selection, 'selected text');
  page = {pdfUrl: 'https://example.test/embedded.pdf'};
  await message('captureAuto');
  assert.equal(sent.action, 'capturePdfFile');
  assert.equal(sent.path, '/tmp/paper.pdf');
  assert.equal(listeners.size, 0, 'already completed download must settle and remove listener');
  page = {};
  tab.url = 'https://example.test/paper.pdf';
  await message('capturePdf');
  assert.equal(sent.action, 'capturePdfFile');
  state = 'in_progress';
  const pending = message('capturePdf');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(listeners.size, 1);
  state = 'complete';
  for (const listener of listeners) listener({id: 7, state: {current: state}});
  assert.equal((await pending).ok, true);
  state = 'interrupted';
  assert.match((await message('capturePdf')).error, /interrupted/);
  assert.equal(listeners.size, 0);
  state = 'complete';
  tab.url = 'https://example.test/article';
  assert.match((await message('capturePdf')).error, /no detectable PDF/);
  await contextClick({menuItemId: 'zettypst-capture-page'}, tab);
  assert.equal(sent.action, 'capturePage');
  await contextClick({menuItemId: 'zettypst-capture-link-pdf', linkUrl: 'https://example.test/file.pdf'}, tab);
  assert.equal(sent.action, 'capturePdfFile');
  assert.match((await message('unknown')).error, /Unknown action/);
  console.log('PASS browser routing: auto/page/PDF, embedded PDF, context menus, completed/in-progress/interrupted downloads');
})().catch(error => {console.error(error); process.exitCode = 1;});
