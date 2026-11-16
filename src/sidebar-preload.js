const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('sb', {
  send: (cmd, a, b, c) => ipcRenderer.send('sb', cmd, a, b, c),
  on: (ch, fn) => ipcRenderer.on(ch, (_e, payload) => fn(payload)),
});
