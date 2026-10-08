'use strict';
const addon = require(process.env.XODB_NODE_PROBE);
const fs = require('node:fs');
let session;
if (process.argv[2] === 'inspector') {
  const {Session} = require('node:inspector');
  session = new Session(); session.connect();
  session.post('Debugger.enable');
  session.on('Debugger.paused', ({params}) => {
    const frames = [];
    const queries = {twoContexts:['p','captured','outer()','inner()'], sample:['p','captured','stackOnly','hold()'], contextInner:['v','captured','outerSeed'],
      recursive:['depth','own'], generate:['seed','phase'], asynchronous:['seed','captured'], mutating:['mutable']};
    for (const frame of params.callFrames) {
      const expressions = queries[frame.functionName];
      if (!expressions) continue;
      const values = {}, scopes = [];
      for (const expression of expressions) {
        session.post('Debugger.evaluateOnCallFrame', {callFrameId:frame.callFrameId,expression,returnByValue:true}, (err,r) => {
          if (err || r.exceptionDetails) throw new Error(JSON.stringify(err || r));
          values[expression] = r.result.value;
        });
      }
      for (const scope of frame.scopeChain.filter(s=>s.type !== 'global')) {
        session.post('Runtime.getProperties',{objectId:scope.object.objectId,ownProperties:true},(err,r)=>{
          if (err) throw err;
          scopes.push({type:scope.type,values:r.result.filter(p=>p.value && 'value' in p.value).map(p=>({name:p.name,value:p.value.value}))});
        });
      }
      frames.push({name:frame.functionName,values,scopes});
    }
    if (!frames.length) throw new Error('missing owned frame');
    fs.writeSync(1, JSON.stringify({oracle:frames})+'\n');
    session.post('Debugger.resume');
  });
}
function sample(p) {
  let captured = 41;
  const hold = () => captured + p;
  let stackOnly = 17;
  {
    let captured = 99;
    debugger;
    addon.probe(hold, 'context-shadow');
    return stackOnly + captured + hold();
  }
}
function twoContexts(p) {
  let captured = 41;
  const outer = () => captured + p;
  {
    let captured = 99;
    const inner = () => captured;
    debugger;
    addon.probe([outer, inner], 'two-contexts');
    return outer() + inner();
  }
}
function makeOuter(seed) {
  let outerSeed = seed;
  return function contextInner(v) {
    let captured = 13;
    const keep = () => v + captured + outerSeed;
    debugger;
    addon.probe(keep, 'closure');
    return keep();
  };
}
function recursive(depth) {
  let own = depth * 10;
  const keep = () => depth + own;
  if (depth) recursive(depth - 1);
  debugger;
  addon.probe(keep, 'recursive-' + depth);
  return keep();
}
function* generate(seed) {
  let phase = 0;
  const keep = () => seed + phase;
  debugger;
  addon.probe(keep, 'generator-0');
  yield keep();
  phase = 1;
  debugger;
  addon.probe(keep, 'generator-1');
  return keep();
}
async function asynchronous(seed) {
  let captured = 29;
  const keep = () => seed + captured;
  await Promise.resolve();
  debugger;
  addon.probe(keep, 'async');
  return keep();
}
function mutating() {
  let mutable = 1;
  const keep = () => mutable;
  mutable = 3.5;
  debugger;
  addon.probe(keep, 'cell-double');
  mutable = -104;
  if (global.gc) global.gc();
  debugger;
  addon.probe(keep, 'cell-integer');
  return keep();
}
fs.writeSync(1,'ready\n');
process.stdin.once('data',async()=>{
  const result = sample(7);
  if (result !== 164) throw new Error('fixture result mismatch');
  if (twoContexts(7) !== 147) throw new Error('two-context result mismatch');
  if (makeOuter(37)(5) !== 55) throw new Error('closure mismatch');
  recursive(2);
  const it = generate(11);
  if (it.next().value !== 11) throw new Error('generator first mismatch');
  if (global.gc) global.gc();
  if (it.next().value !== 12) throw new Error('generator resume mismatch');
  if (await asynchronous(3) !== 32) throw new Error('async mismatch');
  if (mutating() !== -104) throw new Error('cell mismatch');
  if (session) session.disconnect();
  process.stdin.destroy();
});
