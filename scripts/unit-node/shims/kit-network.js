const http = {
  RequestMethod: { GET: 'GET', POST: 'POST', PUT: 'PUT', DELETE: 'DELETE' },
  HttpDataType: { STRING: 0 },
  createHttp: () => ({
    request: async () => { throw new Error('network disabled in unit tests'); },
    destroy: () => {}
  })
};
const connection = {
  NetBearType: { BEARER_CELLULAR: 0, BEARER_WIFI: 1, BEARER_ETHERNET: 3 },
  getDefaultNetSync: () => { throw new Error('no network in unit tests'); },
  getNetCapabilitiesSync: () => ({ bearerTypes: [] }),
  createNetConnection: () => ({ on: () => {}, register: () => {}, unregister: () => {} })
};
module.exports = { http, connection };
