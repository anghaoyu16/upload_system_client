let client = null;

function start(cfg, handlers) {
    stop();
    let createClient;
    try {
        createClient = require('node-rdpjs').createClient;
    } catch (e) {
        if (handlers.onStatus) handlers.onStatus({ state: 'error', message: 'node-rdpjs 未安装：npm install node-rdpjs' });
        return false;
    }
    if (!cfg || !cfg.userName || cfg.password === undefined) {
        if (handlers.onStatus) handlers.onStatus({ state: 'error', message: '缺少 userName / password' });
        return false;
    }

    client = createClient({
        domain: cfg.domain || '',
        userName: cfg.userName,
        password: cfg.password,
        screen: { width: cfg.width || 1280, height: cfg.height || 720 },
        locale: 'zh-CN',
        autoReconnect: false
    });

    client.on('connect', () => { if (handlers.onStatus) handlers.onStatus({ state: 'connected' }); });
    client.on('bitmap', (bmp) => {
        if (handlers.onFrame) handlers.onFrame({
            left: bmp.destLeft || 0,
            top: bmp.destTop || 0,
            width: bmp.width,
            height: bmp.height,
            bitsPerPixel: bmp.bitsPerPixel,
            data: bmp.data
        });
    });
    client.on('close', () => { if (handlers.onStatus) handlers.onStatus({ state: 'disconnected' }); });
    client.on('error', (err) => {
        if (handlers.onStatus) handlers.onStatus({ state: 'error', message: (err && err.message) || String(err) });
    });

    client.connect(cfg.host || 'localhost', cfg.port || 3389);
    return true;
}

function stop() {
    if (client) { try { client.close(); } catch (e) {} client = null; }
}

function sendPointer(x, y, button, isPressed) {
    if (client) client.sendPointerEvent(x, y, button, isPressed);
}
function sendKeyUnicode(code, isPressed) {
    if (client) client.sendKeyEventUnicode(code, isPressed);
}

module.exports = { start, stop, sendPointer, sendKeyUnicode };