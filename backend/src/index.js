// Entry point: check config, connect to MongoDB, seed, listen, shut down gracefully.
const mongoose = require('mongoose');
const app = require('./app');
const { Course, sampleCourses } = require('./models');

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
