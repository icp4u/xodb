'use strict';
const addon = require(process.env.XODB_NODE_PROBE);
const fs = require('node:fs');
let inspectorSession, inspectorLabel;
if (process.argv[2] === 'inspector') {
  const {Session} = require('node:inspector');
  inspectorSession = new Session(); inspectorSession.connect();
  inspectorSession.post('Debugger.enable');
  inspectorSession.on('Debugger.paused', ({params}) => {
    const frames = [];
    for (const frame of params.callFrames) {
      if (frame.functionName !== 'watched' && frame.functionName !== 'recursive') continue;
      const result = {name:frame.functionName};
      const expressions = frame.functionName === 'watched' ? {
        values:'JSON.stringify(Object.fromEntries(Object.entries(keep()).map(([k,v])=>[k,scalar(v)])))',
        bare_x:'JSON.stringify(scalar(x))'
      } : {values:'JSON.stringify({depth:scalar(depth),own:scalar(own)})'};
      for (const [name,expression] of Object.entries(expressions)) {
        inspectorSession.post('Debugger.evaluateOnCallFrame', {callFrameId:frame.callFrameId,expression,returnByValue:true}, (err,r) => {
          if (err || r.exceptionDetails) throw new Error(JSON.stringify(err || r));
          result[name] = JSON.parse(r.result.value);
        });
      }
      frames.push(result);
    }
    fs.writeSync(1, JSON.stringify({inspector:frames,label:inspectorLabel})+'\n');
    inspectorSession.post('Debugger.resume');
  });
}
function scalar(value) {
  let kind, bytes = Buffer.alloc(0);
  if (typeof value === 'number') { kind = 1; bytes = Buffer.alloc(8); bytes.writeDoubleLE(value); }
  else if (typeof value === 'string') { kind = 2; bytes = Buffer.from(value, 'utf16le'); }
  else if (value === false) kind = 3;
  else if (value === true) kind = 4;
  else if (value === null) kind = 5;
  else if (value === undefined) kind = 6;
  else return {complete:false};
  return {kind, hex:bytes.toString('hex'), complete:bytes.length <= 4096};
}
function stop(label, values, keep) {
  fs.writeSync(1, JSON.stringify({label, values:Object.fromEntries(Object.entries(values).map(([k,v])=>[k,scalar(v)]))})+'\n');
  if (inspectorSession) { inspectorLabel = label; debugger; }
  addon.probe(keep, label, values.word);
}
function recursive(depth) {
  let own = depth * 10;
  const keep = () => [depth, own];
  if (depth) recursive(depth - 1);
  stop('recursive-'+depth, {depth,own}, keep);
  return keep();
}
function watched() {
  let x = 7, word = 'q'.repeat(512)+'a', fraction = 3.5, truth = true;
  let empty = undefined, object = {}, large = 'z'.repeat(2049);
  const keep = () => ({x,word,fraction,truth,empty,object,large});
  stop('initial', keep(), keep);
  global.gc();
  stop('gc-equal', keep(), keep);
  x = 8; word = 'q'.repeat(512)+'b'; fraction = -104; truth = false; empty = null;
  global.gc();
  stop('changed', keep(), keep);
  word = ('_'+word).slice(1);
  stop('equal', keep(), keep);
  word = 7; fraction = -0;
  stop('typed', keep(), keep);
  word = '\0\udc00\u202e😀'; fraction = 0; large = 'z'.repeat(2048);
  stop('cap', keep(), keep);
  large += 'z'; fraction = NaN;
  stop('limit', keep(), keep);
  large = 'ok'; word = '';
  stop('recovered', keep(), keep);
  {
    let x = 999;
    const inner = () => x;
    stop('inner-scope', {...keep(),inner:x}, [keep,inner]);
  }
  stop('outer-scope', keep(), keep);
  recursive(2);
  stop('unwound', keep(), keep);
  return keep();
}
fs.writeSync(1, 'ready\n');
let input = '';
process.stdin.on('data', chunk => {
  input += chunk;
  if (!input.includes('\n')) return;
  process.stdin.removeAllListeners('data'); process.stdin.pause();
  watched();
  stop('gone', {}, null);
  watched();
  if (inspectorSession) inspectorSession.disconnect();
});
