import { useEffect, useState } from 'react';

async function api(path, { token, body, method } = {}) {
  const res = await fetch(`/api${path}`, {
    method: method || (body ? 'POST' : 'GET'),
    headers: {
      ...(body && { 'Content-Type': 'application/json' }),
      ...(token && { Authorization: `Bearer ${token}` }),
    },
    body: body && JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw Object.assign(new Error(data.error || 'Request failed'), { status: res.status });
  return data;
}

function AuthForm({ onAuth }) {
  const [mode, setMode] = useState('login');
  const [form, setForm] = useState({ name: '', email: '', password: '' });
  const [error, setError] = useState('');
  const set = (k) => (e) => setForm({ ...form, [k]: e.target.value });

  const submit = async (e) => {
    e.preventDefault();
    setError('');
    try {
      onAuth(await api(`/auth/${mode}`, { body: form }));
    } catch (err) {
      setError(err.message);
    }
  };

  return (
    <form className="card" onSubmit={submit}>
      <h2>{mode === 'login' ? 'Log in' : 'Create your account'}</h2>
      {mode === 'register' && <input placeholder="Full name" value={form.name} onChange={set('name')} required />}
      <input type="email" placeholder="Email" value={form.email} onChange={set('email')} required />
      <input type="password" placeholder="Password (min 8 characters)" value={form.password} onChange={set('password')} required />
      {error && <p className="error">{error}</p>}
      <button type="submit">{mode === 'login' ? 'Log in' : 'Sign up'}</button>
      <p className="switch">
        {mode === 'login' ? 'New here? ' : 'Already registered? '}
        <a href="#" onClick={(e) => { e.preventDefault(); setError(''); setMode(mode === 'login' ? 'register' : 'login'); }}>
          {mode === 'login' ? 'Create an account' : 'Log in'}
        </a>
      </p>
    </form>
  );
}

function Courses({ token, onExpired }) {
  const [courses, setCourses] = useState(null);
  const [error, setError] = useState('');

  useEffect(() => {
    api('/courses', { token })
      .then(setCourses)
      .catch((err) => (err.status === 401 ? onExpired() : setError(err.message)));
  }, [token]);

  const [form, setForm] = useState({ title: '', level: '', description: '', weeks: '' });
  const set = (k) => (e) => setForm({ ...form, [k]: e.target.value });

  const run = async (fn) => {
    setError('');
    try {
      await fn();
    } catch (err) {
      err.status === 401 ? onExpired() : setError(err.message);
    }
  };

  const add = (e) => {
    e.preventDefault();
    run(async () => {
      const course = await api('/courses', { token, body: form });
      setCourses([...courses, course]);
      setForm({ title: '', level: '', description: '', weeks: '' });
    });
  };

  const remove = (id) =>
    run(async () => {
      await api(`/courses/${id}`, { token, method: 'DELETE' });
      setCourses(courses.filter((c) => c._id !== id));
    });

  if (!courses) return error ? <p className="error">{error}</p> : <p>Loading courses…</p>;
  return (
    <>
      <form className="card add" onSubmit={add}>
        <h3>Add your own course</h3>
        <input placeholder="Title" value={form.title} onChange={set('title')} required />
        <input placeholder="Level (e.g. GCSE)" value={form.level} onChange={set('level')} required />
        <input placeholder="Description" value={form.description} onChange={set('description')} required />
        <input type="number" min="1" max="104" placeholder="Weeks" value={form.weeks} onChange={set('weeks')} required />
        <button type="submit">Add course</button>
      </form>
      {error && <p className="error">{error}</p>}
      <div className="grid">
        {courses.map((c) => (
          <div className="card course" key={c._id}>
            <span className="tag">{c.level}</span>
            {c.mine && <span className="tag mine">Yours</span>}
            <h3>{c.title}</h3>
            <p>{c.description}</p>
            <small>{c.weeks} weeks</small>
            {c.mine && <button className="delete" onClick={() => remove(c._id)}>Delete</button>}
          </div>
        ))}
      </div>
    </>
  );
}

export default function App() {
  const [session, setSession] = useState(() => JSON.parse(localStorage.getItem('session') || 'null'));

  const save = (s) => {
    s ? localStorage.setItem('session', JSON.stringify(s)) : localStorage.removeItem('session');
    setSession(s);
  };

  return (
    <>
      <header>
        <h1>StudyUK</h1>
        {session && (
          <div>
            <span>Hi, {session.user.name}</span>
            <button className="link" onClick={() => save(null)}>Log out</button>
          </div>
        )}
      </header>
      <main>
        {session ? (
          <>
            <h2>Courses</h2>
            <Courses token={session.token} onExpired={() => save(null)} />
          </>
        ) : (
          <AuthForm onAuth={save} />
        )}
      </main>
    </>
  );
}
