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
const target = path.join(directory, 'blueprint.json');
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
function validate(data) {
  if (!data || ![1,2].includes(data.version) || !Array.isArray(data.blocks) || data.blocks.length<1 || data.blocks.length>900) throw Error('Нужно от 1 до 900 блоков в чертеже версии 1 или 2');
  const version=data.version;
  const cells = new Set();
  for (const b of data.blocks) {
    const size=b?.size??1;
    if (!b || b.type!=='stone' || ![1,2,4].includes(size) || (version===1&&size!==1) || !Number.isInteger(b.x) || !Number.isInteger(b.y) || b.x<0 || b.y<0 || b.x+size>59 || b.y+size>30) throw Error('Допустимы каменные блоки 1×1, 2×2 или 4×4 в сетке 59×30');
    for(let dy=0;dy<size;dy++)for(let dx=0;dx<size;dx++){const k=`${b.x+dx},${b.y+dy}`;if(cells.has(k))throw Error(`Блоки пересекаются в клетке ${k}`);cells.add(k);}
  }
  const blocks=data.blocks.map(({x,y,size=1})=>({x,y,type:'stone',size})).sort((a,b)=>a.y-b.y||a.x-b.x);
  return {version:blocks.some(b=>b.size>1)?2:version,blocks};
}
function reply(res,code,value,type='application/json; charset=utf-8') {res.writeHead(code,{'Content-Type':type,'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});res.end(value);}
const server=http.createServer(async (req,res)=>{
  const host=`127.0.0.1:${server.address().port}`;
  if(req.headers.host!==host) return reply(res,403,'Forbidden','text/plain');
  if(req.method==='GET'&&req.url==='/') return reply(res,200,fs.readFileSync(path.join(__dirname,'index.html')),'text/html; charset=utf-8');
  if(req.method==='GET'&&req.url==='/api/blueprint') {
    try {
      const saved=validate(JSON.parse(fs.readFileSync(target,'utf8')));
      return reply(res,200,JSON.stringify({...saved,isDefault:false}));
    } catch(e) {
      if(e.code==='ENOENT')return reply(res,200,JSON.stringify(defaultBlueprint()));
      if(e.code)return reply(res,500,JSON.stringify({error:'Ошибка чтения чертежа: '+e.message}));
      return reply(res,200,JSON.stringify({...defaultBlueprint(),warning:'Сохранённый чертёж повреждён. Игра использует стандартную пирамиду; файл не изменён.'}));
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
      if(fs.existsSync(target))validate(JSON.parse(fs.readFileSync(target,'utf8')));
      if(fs.existsSync(settingsTarget))validateSettings(JSON.parse(fs.readFileSync(settingsTarget,'utf8')));
      fs.mkdirSync(directory,{recursive:true});
      const requestId=crypto.randomUUID();
      const temporary=path.join(directory,`.reset-${requestId}.tmp`);
      try{fs.writeFileSync(temporary,requestId,'utf8');fs.renameSync(temporary,resetTarget);}
      finally{fs.rmSync(temporary,{force:true});}
      return reply(res,202,JSON.stringify({status:'queued'}));
    } catch(e){return reply(res,e.code?500:400,JSON.stringify({error:e.message}));}
  }
  if(!['/api/blueprint','/api/settings'].includes(req.url))return reply(res,404,'Not found','text/plain');
  const destination = req.url==='/api/settings' ? settingsTarget : target;
  if(req.headers.origin!==`http://${host}`)return reply(res,403,'Forbidden','text/plain');
  if(req.method==='DELETE') {try{fs.rmSync(destination,{force:true});return reply(res,200,'{}');}catch(e){return reply(res,500,JSON.stringify({error:e.message}));}}
  if(req.method!=='PUT'||!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type']||''))return reply(res,405,'Method not allowed','text/plain');
  try {
    let body=''; for await(const chunk of req){body+=chunk;if(Buffer.byteLength(body)>100000)throw Error('Недопустимый размер запроса');}
    const result=(req.url==='/api/settings'?validateSettings:validate)(JSON.parse(body));fs.mkdirSync(directory,{recursive:true});
    const tmp=path.join(directory,`.blueprint-${crypto.randomBytes(8).toString('hex')}.tmp`);
    try{fs.writeFileSync(tmp,JSON.stringify(result,null,2));fs.renameSync(tmp,destination);}finally{fs.rmSync(tmp,{force:true});}
    return reply(res,200,JSON.stringify(result));
  } catch(e){return reply(res,400,JSON.stringify({error:e.message}));}
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
