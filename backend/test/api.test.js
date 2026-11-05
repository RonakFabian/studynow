// Integration tests against a real MongoDB (set MONGO_URI; CI uses a service container).
// Run: MONGO_URI=mongodb://127.0.0.1:27017/studyuk_test npm test
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const mongoose = require('mongoose');

process.env.JWT_SECRET = 'test-secret';
process.env.APP_VERSION = 'test';
const app = require('../src/app');
const { Course } = require('../src/models');

let server;
let base;

const call = async (path, { method = 'GET', body, token } = {}) => {
  const res = await fetch(base + path, {
    method,
    headers: {
      ...(body && { 'Content-Type': 'application/json' }),
      ...(token && { Authorization: `Bearer ${token}` }),
    },
    body: body && JSON.stringify(body),
  });
  const text = await res.text();
  return { status: res.status, json: text ? JSON.parse(text) : null };
};

const register = async (name) =>
  (await call('/api/auth/register', { method: 'POST', body: { name, email: `${name}@example.com`, password: 'password123' } })).json;

before(async () => {
  await mongoose.connect(process.env.MONGO_URI || 'mongodb://127.0.0.1:27017/studyuk_test');
  await mongoose.connection.dropDatabase();
  await mongoose.syncIndexes();
  await Course.create({ title: 'Shared GCSE Maths', level: 'GCSE', description: 'seed', weeks: 5 });
  server = app.listen(0);
  base = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  server.close();
  await mongoose.connection.dropDatabase();
  await mongoose.disconnect();
});

test('health reports ok, db up and version', async () => {
  const { status, json } = await call('/api/health');
  assert.equal(status, 200);
  assert.deepEqual(json, { status: 'ok', db: true, version: 'test' });
});

test('register validates input and rejects duplicates', async () => {
  const bad = await call('/api/auth/register', { method: 'POST', body: { name: 'x', email: 'x@example.com', password: 'short' } });
  assert.equal(bad.status, 400);
  assert.ok((await register('alice')).token);
  const dup = await call('/api/auth/register', { method: 'POST', body: { name: 'alice', email: 'alice@example.com', password: 'password123' } });
  assert.equal(dup.status, 409);
});

test('login accepts the right password only', async () => {
  const wrong = await call('/api/auth/login', { method: 'POST', body: { email: 'alice@example.com', password: 'nope-nope' } });
  assert.equal(wrong.status, 401);
  const ok = await call('/api/auth/login', { method: 'POST', body: { email: 'alice@example.com', password: 'password123' } });
  assert.equal(ok.status, 200);
  assert.ok(ok.json.token);
});

test('courses require a login', async () => {
  assert.equal((await call('/api/courses')).status, 401);
  assert.equal((await call('/api/courses', { token: 'garbage' })).status, 401);
});

test('users add and delete only their own courses', async () => {
  const alice = (await register('alice2')).token;
  const bob = (await register('bob')).token;

  const created = await call('/api/courses', { method: 'POST', token: alice, body: { title: 'Alice course', level: 'A-Level', description: 'mine', weeks: 4 } });
  assert.equal(created.status, 201);
  assert.equal(created.json.mine, true);
  const id = created.json._id;

  const aliceList = (await call('/api/courses', { token: alice })).json;
  assert.ok(aliceList.some((c) => c._id === id && c.mine));
  assert.ok(aliceList.some((c) => c.title === 'Shared GCSE Maths' && !c.mine));

  const bobList = (await call('/api/courses', { token: bob })).json;
  assert.ok(!bobList.some((c) => c._id === id), "bob must not see alice's course");

  assert.equal((await call(`/api/courses/${id}`, { method: 'DELETE', token: bob })).status, 404);
  assert.equal((await call(`/api/courses/${id}`, { method: 'DELETE', token: alice })).status, 204);
  assert.equal((await call(`/api/courses/${id}`, { method: 'DELETE', token: alice })).status, 404);
});

test('shared catalogue courses cannot be deleted; bad input is rejected', async () => {
  const token = (await register('carol')).token;
  const shared = (await call('/api/courses', { token })).json.find((c) => c.title === 'Shared GCSE Maths');
  assert.equal((await call(`/api/courses/${shared._id}`, { method: 'DELETE', token })).status, 404);
  assert.equal((await call('/api/courses/not-an-id', { method: 'DELETE', token })).status, 404);
  const bad = await call('/api/courses', { method: 'POST', token, body: { title: 'x', level: 'y', description: 'z', weeks: 500 } });
  assert.equal(bad.status, 400);
});
