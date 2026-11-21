'use strict';
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawn} = require('node:child_process');
const args = process.argv.slice(2);
const option = (name, fallback) => {const i=args.indexOf(name);return i<0?fallback:args[i+1]};
const port = Number(option('--port', '8765'));
const urlFile = option('--url-file', '');
const automaticPort = !args.includes('--port');
let listenPort = port;
let portAttempts = 0;
const directory = option('--user-dir', path.join(process.env.APPDATA, 'Godot', 'app_userdata', 'Пирамида', 'wallpaper'));
const legacyBlueprint = path.join(directory, 'blueprint.json');
const blueprintDirectory = path.join(directory, 'blueprints');
const selectionFile = path.join(directory, 'blueprint-selection.txt');
const reloadRequest = path.join(directory, 'reload.request');
const presetDirectory = path.join(directory, 'block-presets');
const textureDirectory = path.join(directory, 'textures');
const textureFields = ['rawTexture', 'finishedTexture'];
const blockSizes = [1, 2, 4];
const maxTextureBytes = 1024 * 1024;
const pngSignature = Buffer.from('89504e470d0a1a0a', 'hex');
const textureHash = /^[a-f0-9]{64}$/;
const settingsTarget = path.join(directory, 'settings.json');
const resetTarget = path.join(directory, 'reset.request');
const balance = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', 'data', 'balance.json'), 'utf8'));
const defaults = {
  version:1,
  sizePenalty:1.5,
  minerCount:balance.workers.miner.count ?? 1,
  minerMove:balance.workers.miner.moveSpeed,
  mineSeconds:balance.workers.miner.mineSeconds,
  porterCount:balance.workers.porter.count,
  porterEmpty:balance.workers.porter.emptySpeed,
  porterLoaded:balance.workers.porter.loadedSpeed,
  loadSeconds:balance.workers.porter.loadSeconds,
  unloadSeconds:balance.workers.porter.unloadSeconds,
  dresserCount:balance.workers.dresser.count ?? 1,
  dresserMove:balance.workers.dresser.moveSpeed ?? balance.workers.builder.moveSpeed,
  dressSeconds:balance.workers.dresser.processSeconds,
  builderCount:balance.workers.builder.count ?? 1,
  builderMove:balance.workers.builder.moveSpeed,
  placeSeconds:balance.workers.builder.placeSeconds,
  liftBase:balance.lift.baseSeconds,
  liftPerRow:balance.lift.secondsPerRow,
  rebuildSeconds:balance.lift.rebuildSeconds,
  weatherMin:100, weatherMax:200, weatherTransition:24,
  clearWeight:1, partlyWeight:1, cloudyWeight:1
};
const defaultBlueprint = () => {
  const world=balance.world;
  const blocks=[];
  for(let y=0;y<world.pyramidRows;y++) {
    const width=world.pyramidBaseRowBricks-y*world.rowWidthDecrease;
    const first=(world.pyramidBaseRowBricks-width)/2;
    for(let column=0;column<width;column++) blocks.push({x:first+column,y,type:'stone',size:1});
  }
  return {version:1,blocks,isDefault:true};
};
const limits = {sizePenalty:[1,10],minerMove:[.1,20],mineSeconds:[.1,120],porterEmpty:[.1,20],porterLoaded:[.1,20],loadSeconds:[.1,120],unloadSeconds:[.1,120],dressSeconds:[.1,120],dresserMove:[.1,20],builderMove:[.1,20],placeSeconds:[.1,120],liftBase:[.1,120],liftPerRow:[0,30],rebuildSeconds:[.1,120],porterCount:[1,4],minerCount:[1,4],dresserCount:[1,4],builderCount:[1,4],weatherMin:[1,3600],weatherMax:[1,3600],weatherTransition:[.1,3600],clearWeight:[0,100],partlyWeight:[0,100],cloudyWeight:[0,100]};
function validateSettings(value) {
  if (!value || value.version!==1) throw Error('Неверная версия настроек');
  const result={version:1};
  for (const [key,[min,max]] of Object.entries(limits)) {
    const n=key==='sizePenalty'&&value[key]===undefined?1.5:value[key]; if(typeof n!=='number'||!Number.isFinite(n)||n<min||n>max) throw Error(`Недопустимое значение: ${key}`); result[key]=n;
  }
  if (['porterCount','minerCount','dresserCount','builderCount'].some(key=>!Number.isInteger(result[key]))||result.weatherMin>result.weatherMax||result.clearWeight+result.partlyWeight+result.cloudyWeight<=0) throw Error('Проверьте число рабочих, интервалы и вероятности');
  return result;
}
const blueprintWidth = 177;
const blueprintHeight = 90;
function validate(data) {
  if (!data || ![1, 2, 3].includes(data.version) || !Array.isArray(data.blocks)
      || data.blocks.length < 1 || data.blocks.length > 900) {
    throw Error('Нужно от 1 до 900 блоков в чертеже версии 1, 2 или 3.');
  }
  const cells = new Set();
  const blocks = data.blocks.map(block => {
    const {x, y, type = 'stone', size = 1} = block ?? {};
    if (type !== 'stone' || !blockSizes.includes(size) || (data.version === 1 && size !== 1)
        || !Number.isInteger(x) || !Number.isInteger(y)
        || x < 0 || y < 0 || x + size > blueprintWidth || y + size > blueprintHeight) {
      throw Error('Допустимы каменные блоки 1×1, 2×2 или 4×4 в сетке 177×90.');
    }
    for (let dy = 0; dy < size; dy++) {
      for (let dx = 0; dx < size; dx++) {
        const cell = [x + dx, y + dy].join(',');
        if (cells.has(cell)) throw Error('Блоки пересекаются в клетке ' + cell + '.');
        cells.add(cell);
      }
    }
    const normalized = {x, y, type, size};
    for (const field of textureFields) {
      if (block[field] === undefined) continue;
      if (data.version !== 3 || typeof block[field] !== 'string' || !textureHash.test(block[field])) {
        throw Error('Недопустимая ссылка на текстуру.');
      }
      normalized[field] = block[field];
    }
    return normalized;
  });
  blocks.sort((a, b) => a.y - b.y || a.x - b.x);
  return {version: data.version, blocks};
}

function displayName(input) {
  const name = typeof input === 'string' ? input.trim() : '';
  if (!name || name.length > 60 || /[<>:"/\\|?*&\p{Cc}\p{Cf}\p{Cs}]/u.test(name)) {
    throw Error('Введите название до 60 символов без служебных знаков.');
  }
  return name;
}

function readText(file, fallback = '') {
  try { return fs.readFileSync(file, 'utf8'); }
  catch (error) { if (error.code === 'ENOENT') return fallback; throw error; }
}

function listFiles(folder, prefix) {
  try {
    return fs.readdirSync(folder, {withFileTypes: true})
      .filter(entry => entry.isFile() && entry.name.startsWith(prefix) && entry.name.endsWith('.json'))
      .map(entry => entry.name.slice(0, -5));
  } catch (error) {
    if (error.code === 'ENOENT') return [];
    throw error;
  }
}

function listBlueprints() {
  const entries = [{id: 'default', name: 'Стандартная пирамида'}];
  if (fs.existsSync(legacyBlueprint)) entries.push({id: 'legacy', name: 'Прежний чертёж'});
  const named = listFiles(blueprintDirectory, 'b-').sort((a, b) => a.localeCompare(b, 'ru'));
  return entries.concat(named.map(id => ({id, name: id.slice(2)})));
}

function selectedBlueprint(entries = listBlueprints()) {
  const fallback = entries.some(entry => entry.id === 'legacy') ? 'legacy' : 'default';
  const selected = readText(selectionFile, fallback);
  return entries.some(entry => entry.id === selected) ? selected : 'default';
}

function blueprintPath(id) {
  if (id === 'legacy') return legacyBlueprint;
  if (typeof id !== 'string' || !id.startsWith('b-') || displayName(id.slice(2)) !== id.slice(2)) {
    throw Error('Неизвестный чертёж.');
  }
  return path.join(blueprintDirectory, id + '.json');
}

function readBlueprint(id) {
  return id === 'default' ? defaultBlueprint()
    : {...validate(JSON.parse(fs.readFileSync(blueprintPath(id), 'utf8'))), isDefault: false};
}

function atomicWrite(destination, data, create = false) {
  const folder = path.dirname(destination);
  fs.mkdirSync(folder, {recursive: true});
  const temporary = path.join(folder, '.' + crypto.randomUUID() + '.tmp');
  try {
    fs.writeFileSync(temporary, data);
    if (create) fs.linkSync(temporary, destination);
    else fs.renameSync(temporary, destination);
  } finally {
    fs.rmSync(temporary, {force: true});
  }
}

function readPng(value) {
  if (typeof value !== 'string' || value.length > Math.ceil(maxTextureBytes / 3) * 4) {
    throw Error('Размер текстуры не должен превышать 1 МБ.');
  }
  const data = Buffer.from(value, 'base64');
  if (data.length < 45 || data.length > maxTextureBytes || data.toString('base64') !== value
      || !data.subarray(0, 8).equals(pngSignature) || data.readUInt32BE(8) !== 13
      || data.toString('ascii', 12, 16) !== 'IHDR') {
    throw Error('Выберите корректный файл PNG.');
  }
  const width = data.readUInt32BE(16);
  const height = data.readUInt32BE(20);
  if (!width || !height || width > 512 || height > 512) {
    throw Error('Ширина и высота текстуры должны быть от 1 до 512 пикселей.');
  }
  return data;
}

function savePreset(data) {
  const name = displayName(data?.name);
  const size = data?.size;
  if (!blockSizes.includes(size)) throw Error('Выберите размер 1×1, 2×2 или 4×4.');
  const preset = {id: 'p-' + name, name, size};
  const destination = path.join(presetDirectory, preset.id + '.json');
  if (fs.existsSync(destination)) throw Error('Блок с таким названием уже есть.');
  const images = textureFields.filter(field => data[field] !== undefined);
  if (!images.length) throw Error('Загрузите хотя бы одну текстуру.');
  const textures = images.map(field => [field, readPng(data[field])]);
  for (const [field, image] of textures) {
    const hash = crypto.createHash('sha256').update(image).digest('hex');
    const file = path.join(textureDirectory, hash + '.png');
    if (!fs.existsSync(file)) atomicWrite(file, image);
    preset[field] = hash;
  }
  atomicWrite(destination, JSON.stringify(preset), true);
  return preset;
}

async function requestJson(req, limit) {
  if (!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type'] || '')) {
    throw Error('Ожидаются данные JSON.');
  }
  const chunks = [];
  let length = 0;
  for await (const chunk of req.iterator({destroyOnReturn: false})) {
    length += chunk.length;
    if (length > limit) throw Error('Недопустимый размер запроса.');
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

function reply(res,code,value,type='application/json; charset=utf-8') {res.writeHead(code,{'Content-Type':type,'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});res.end(value);}
const server=http.createServer(async (req,res)=>{
  const host=`127.0.0.1:${server.address().port}`;
  if(req.headers.host!==host) return reply(res,403,'Forbidden','text/plain');
  if(req.method==='GET'&&req.url==='/') return reply(res,200,fs.readFileSync(path.join(__dirname,'index.html')),'text/html; charset=utf-8');
  if (req.method === 'GET') {
    try {
      if (req.url === '/api/blueprints') {
        const entries = listBlueprints();
        return reply(res, 200, JSON.stringify({entries, selection: selectedBlueprint(entries)}));
      }
      if (req.url === '/api/blueprint') {
        const selection = selectedBlueprint();
        try {
          return reply(res, 200, JSON.stringify({...readBlueprint(selection), selection}));
        } catch (error) {
          if (error.code && error.code !== 'ENOENT') throw error;
          const warning = 'Сохранённый чертёж недоступен. Игра использует стандартную пирамиду.';
          return reply(res, 200, JSON.stringify({...defaultBlueprint(), selection, warning}));
        }
      }
      if (req.url === '/api/block-presets') {
        const presets = listFiles(presetDirectory, 'p-').sort((a, b) => a.localeCompare(b, 'ru'))
          .map(id => JSON.parse(fs.readFileSync(path.join(presetDirectory, id + '.json'), 'utf8')));
        return reply(res, 200, JSON.stringify(presets));
      }
      const texture = /^\/api\/textures\/([a-f0-9]{64})$/.exec(req.url);
      if (texture) {
        const file = path.join(textureDirectory, texture[1] + '.png');
        if (!fs.existsSync(file)) return reply(res, 404, '{}');
        return reply(res, 200, fs.readFileSync(file), 'image/png');
      }
    } catch (error) {
      return reply(res, 500, JSON.stringify({error: error.message}));
    }
  }
  if(req.method==='GET'&&req.url==='/api/settings') {
    try {
      return reply(res,200,JSON.stringify({...validateSettings(JSON.parse(fs.readFileSync(settingsTarget,'utf8'))),source:'saved'}));
    } catch(e) {
      if(e.code==='ENOENT')return reply(res,200,JSON.stringify({...defaults,source:'default'}));
      if(e.code)return reply(res,500,JSON.stringify({error:'Ошибка чтения настроек: '+e.message}));
      return reply(res,200,JSON.stringify({...defaults,source:'default',warning:'Сохранённые настройки повреждены. Игра использует исходные значения; файл не изменён.'}));
    }
  }
  if(req.url==='/api/progress/reset') {
    if(req.method==='GET')return reply(res,200,JSON.stringify({pending:fs.existsSync(resetTarget)}));
    if(req.headers.origin!==`http://${host}`)return reply(res,403,'Forbidden','text/plain');
    if(req.method!=='POST')return reply(res,405,'Method not allowed','text/plain');
    try {
      readBlueprint(selectedBlueprint());
      if(fs.existsSync(settingsTarget))validateSettings(JSON.parse(fs.readFileSync(settingsTarget,'utf8')));
      fs.mkdirSync(directory,{recursive:true});
      const requestId=crypto.randomUUID();
      const temporary=path.join(directory,`.reset-${requestId}.tmp`);
      try{fs.writeFileSync(temporary,requestId,'utf8');fs.renameSync(temporary,resetTarget);}
      finally{fs.rmSync(temporary,{force:true});}
      return reply(res,202,JSON.stringify({status:'queued'}));
    } catch(e){return reply(res,e.code?500:400,JSON.stringify({error:e.message}));}
  }
  const routes = {
    '/api/blueprint': ['PUT', 'DELETE'],
    '/api/blueprints': ['POST'],
    '/api/blueprint-selection': ['PUT'],
    '/api/block-presets': ['POST'],
    '/api/settings': ['PUT', 'DELETE'],
  };
  const methods = routes[req.url];
  if (!Array.isArray(methods)) return reply(res, 404, 'Not found', 'text/plain');
  if (req.headers.origin !== 'http://' + host) return reply(res, 403, 'Forbidden', 'text/plain');
  if (!methods.includes(req.method)) return reply(res, 405, 'Method not allowed', 'text/plain');
  try {
    if (req.method === 'DELETE') {
      const file = req.url === '/api/settings' ? settingsTarget : legacyBlueprint;
      fs.rmSync(file, {force: true});
      return reply(res, 200, '{}');
    }
    const data = await requestJson(req, req.url === '/api/block-presets' ? 2_800_000 : 225_000);
    let result;
    switch (req.url) {
      case '/api/settings':
        result = validateSettings(data);
        atomicWrite(settingsTarget, JSON.stringify(result, null, 2));
        break;
      case '/api/blueprint': {
        const id = data?.selection ?? 'legacy';
        if (id !== 'legacy' && !listBlueprints().some(entry => entry.id === id)) {
          throw Error('Чертёж больше недоступен.');
        }
        result = validate(data);
        atomicWrite(blueprintPath(id), JSON.stringify(result, null, 2));
        if (id === selectedBlueprint()) atomicWrite(reloadRequest, '');
        break;
      }
      case '/api/blueprints': {
        const id = 'b-' + displayName(data?.name);
        result = {...validate(data), id};
        const file = blueprintPath(id);
        if (fs.existsSync(file)) throw Error('Чертёж с таким названием уже есть.');
        atomicWrite(file, JSON.stringify({version: result.version, blocks: result.blocks}, null, 2), true);
        break;
      }
      case '/api/blueprint-selection': {
        const id = data?.id;
        if (!listBlueprints().some(entry => entry.id === id)) throw Error('Неизвестный чертёж.');
        result = {...readBlueprint(id), selection: id};
        atomicWrite(selectionFile, id);
        break;
      }
      case '/api/block-presets':
        result = savePreset(data);
        break;
    }
    return reply(res, req.method === 'POST' ? 201 : 200, JSON.stringify(result));
  } catch (error) {
    if (error.code === 'EEXIST') return reply(res, 409, JSON.stringify({error: 'Это название уже занято.'}));
    return reply(res, error.code ? 500 : 400, JSON.stringify({error: error.message}));
  }
});
server.on('error',error=>{
  if(error.code==='EADDRINUSE') {
    if(automaticPort && portAttempts<10 && listenPort<65535) {
      listenPort++;
      portAttempts++;
      server.listen(listenPort,'127.0.0.1');
      return;
    }
    console.error(`Порт ${listenPort} занят. Закройте прежний экземпляр панели или укажите свободный порт через --port.`);
    process.exitCode=1;
    return;
  }
  throw error;
});
server.listen(listenPort,'127.0.0.1',()=>{
  const url=`http://127.0.0.1:${server.address().port}/`;
  if(urlFile) {
    fs.mkdirSync(path.dirname(urlFile),{recursive:true});
    fs.writeFileSync(urlFile,url,'utf8');
  }
  console.log(url);
  if(args.includes('--open')&&process.platform==='win32')spawn('explorer.exe',[url],{detached:true,stdio:'ignore'}).unref();
});
