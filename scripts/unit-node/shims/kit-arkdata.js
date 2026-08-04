// In-memory Preferences (per name), same sync API surface.
const stores = new Map();
const preferences = {
  getPreferencesSync: (_ctx, options) => {
    const name = options && options.name ? options.name : 'default';
    if (!stores.has(name)) stores.set(name, new Map());
    const store = stores.get(name);
    return {
      getSync: (key, def) => (store.has(key) ? store.get(key) : def),
      putSync: (key, value) => { store.set(key, value); },
      deleteSync: (key) => { store.delete(key); },
      flush: (cb) => { if (typeof cb === 'function') cb(undefined); }
    };
  }
};
module.exports = { preferences };
