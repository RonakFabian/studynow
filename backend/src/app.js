// The Express app only: no DB connection and no listen(), so tests can import it.
const express = require('express');
const mongoose = require('mongoose');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { User, Course } = require('./models');

const app = express();
app.use(express.json());

const secret = () => process.env.JWT_SECRET;
const signToken = (user) => jwt.sign({ sub: user.id, name: user.name }, secret(), { expiresIn: '7d' });

const requireAuth = (req, res, next) => {
  const token = (req.headers.authorization || '').replace(/^Bearer /, '');
  try {
    req.user = jwt.verify(token, secret());
    next();
  } catch {
    res.status(401).json({ error: 'Please log in' });
  }
};

// Used by Docker healthchecks and the deploy script: 503 until MongoDB is reachable.
app.get('/api/health', (req, res) => {
  const db = mongoose.connection.readyState === 1;
  res.status(db ? 200 : 503).json({
    status: db ? 'ok' : 'degraded',
    db,
    version: process.env.APP_VERSION || 'dev',
  });
});

app.post('/api/auth/register', async (req, res) => {
  const { name, email, password } = req.body || {};
  if (!name || !email || !password || password.length < 8) {
    return res.status(400).json({ error: 'Name, email and a password of at least 8 characters are required' });
  }
  try {
    const passwordHash = await bcrypt.hash(password, 10);
    const user = await User.create({ name, email, passwordHash });
    res.status(201).json({ token: signToken(user), user: { name: user.name, email: user.email } });
  } catch (err) {
    if (err.code === 11000) return res.status(409).json({ error: 'That email is already registered' });
    console.error(err);
    res.status(500).json({ error: 'Something went wrong' });
  }
});

app.post('/api/auth/login', async (req, res) => {
  const { email, password } = req.body || {};
  const user = email && (await User.findOne({ email: String(email).toLowerCase() }));
  if (!user || !(await bcrypt.compare(String(password || ''), user.passwordHash))) {
    return res.status(401).json({ error: 'Invalid email or password' });
  }
  res.json({ token: signToken(user), user: { name: user.name, email: user.email } });
});

// Shared catalogue courses plus the logged-in user's own courses
app.get('/api/courses', requireAuth, async (req, res) => {
  const courses = await Course.find({ $or: [{ owner: null }, { owner: req.user.sub }] })
    .sort({ level: 1, title: 1 })
    .lean();
  res.json(courses.map((c) => ({ ...c, mine: String(c.owner) === req.user.sub })));
});

app.post('/api/courses', requireAuth, async (req, res) => {
  const { title, level, description, weeks } = req.body || {};
  const w = Number(weeks);
  if (!title?.trim() || !level?.trim() || !description?.trim() || !Number.isInteger(w) || w < 1 || w > 104) {
    return res.status(400).json({ error: 'Title, level, description and weeks (1-104) are required' });
  }
  const course = await Course.create({
    title: title.trim(),
    level: level.trim(),
    description: description.trim(),
    weeks: w,
    owner: req.user.sub,
  });
  res.status(201).json({ ...course.toObject(), mine: true });
});

app.delete('/api/courses/:id', requireAuth, async (req, res) => {
  const ok = mongoose.isValidObjectId(req.params.id);
  const result = ok && (await Course.deleteOne({ _id: req.params.id, owner: req.user.sub }));
  if (!result || !result.deletedCount) {
    return res.status(404).json({ error: 'Course not found (you can only delete your own)' });
  }
  res.status(204).end();
});

module.exports = app;
