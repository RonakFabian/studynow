const express = require('express');
const mongoose = require('mongoose');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { User, Course, sampleCourses } = require('./models');

const {
  MONGO_HOST = 'mongo',
  MONGO_APP_DB,
  MONGO_APP_USER,
  MONGO_APP_PASSWORD,
  JWT_SECRET,
  PORT = 3000,
} = process.env;

if (!JWT_SECRET || !MONGO_APP_DB || !MONGO_APP_USER || !MONGO_APP_PASSWORD) {
  console.error('Missing required environment variables');
  process.exit(1);
}

const app = express();
app.use(express.json());

const signToken = (user) => jwt.sign({ sub: user.id, name: user.name }, JWT_SECRET, { expiresIn: '7d' });

const requireAuth = (req, res, next) => {
  const token = (req.headers.authorization || '').replace(/^Bearer /, '');
  try {
    req.user = jwt.verify(token, JWT_SECRET);
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

async function connectWithRetry(attempts = 10) {
  for (let i = 1; i <= attempts; i++) {
    try {
      await mongoose.connect(`mongodb://${MONGO_HOST}:27017/${MONGO_APP_DB}`, {
        user: MONGO_APP_USER,
        pass: MONGO_APP_PASSWORD,
        authSource: MONGO_APP_DB,
        serverSelectionTimeoutMS: 5000,
      });
      return;
    } catch (err) {
      console.error(`MongoDB connection failed (${i}/${attempts}): ${err.message}`);
      await new Promise((r) => setTimeout(r, 3000));
    }
  }
  process.exit(1);
}

(async () => {
  await connectWithRetry();
  if ((await Course.countDocuments()) === 0) await Course.insertMany(sampleCourses);
  const server = app.listen(PORT, () => console.log(`API listening on ${PORT}`));

  // Graceful shutdown: stop accepting connections, let in-flight requests finish, then exit.
  const shutdown = (signal) => {
    console.log(`${signal} received, shutting down`);
    server.close(async () => {
      await mongoose.disconnect();
      process.exit(0);
    });
    server.closeIdleConnections?.();
    setTimeout(() => process.exit(1), 10000).unref();
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
})();
