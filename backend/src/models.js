const mongoose = require('mongoose');

const User = mongoose.model(
  'User',
  new mongoose.Schema(
    {
      name: { type: String, required: true, trim: true },
      email: { type: String, required: true, unique: true, lowercase: true, trim: true },
      passwordHash: { type: String, required: true },
    },
    { timestamps: true }
  )
);

const Course = mongoose.model(
  'Course',
  new mongoose.Schema({
    title: { type: String, required: true },
    level: { type: String, required: true },
    description: { type: String, required: true },
    weeks: { type: Number, required: true },
    // null = shared catalogue course (seeded); otherwise created by that user
    owner: { type: mongoose.Schema.Types.ObjectId, ref: 'User', default: null, index: true },
  })
);

const sampleCourses = [
  { title: 'GCSE Maths', level: 'GCSE', weeks: 12, description: 'Number, algebra, geometry and statistics for the AQA/Edexcel specifications.' },
  { title: 'GCSE English Language', level: 'GCSE', weeks: 10, description: 'Reading and writing skills, with exam technique for Paper 1 and Paper 2.' },
  { title: 'A-Level Biology', level: 'A-Level', weeks: 16, description: 'Cells, biochemistry, genetics and ecology, with practical endorsement support.' },
  { title: 'A-Level Chemistry', level: 'A-Level', weeks: 16, description: 'Physical, organic and inorganic chemistry with worked exam questions.' },
  { title: 'IELTS Preparation', level: 'English', weeks: 8, description: 'Listening, reading, writing and speaking practice for the IELTS Academic test.' },
  { title: 'Introduction to Python', level: 'Beginner', weeks: 6, description: 'Learn programming fundamentals by building small projects.' },
];

module.exports = { User, Course, sampleCourses };
