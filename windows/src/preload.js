// 覆盖层页面不需要 Node 能力，这里只暴露只读的版本信息，保持 contextIsolation。
const { contextBridge } = require('electron');
contextBridge.exposeInMainWorld('followsound', {
  platform: 'windows',
  version: process.env.FS_VERSION || ''
});
