'use strict';
const addon = require(process.env.XODB_NODE_PROBE);
Error.stackTraceLimit = 160;
let armed = true;
let serial = 0;
function stop(label, value) {
  if (!armed) return;
  ++serial;
  addon.probe(value, label);
}
function nested() {
  function inner(value) { stop('nested', value); }
  function outer(value) { inner(value); }
  outer([1, 'two', true]);
}
function closures() {
  const captured = 7;
  function closure(value) { stop('closure', {value, captured}); }
  closure(11);
}
class Point {
  constructor(x, y) { this.x = x; this.y = y; }
  inspect() { stop('class', this); }
}
async function asynchronous() {
  await Promise.resolve(5);
  stop('async', 'resumed');
}
function* generate() { stop('generator', 'yielding'); yield 42; }
function generatorCase() { for (const value of generate()) void value; }
function recurse(depth) {
  if (depth) recurse(depth - 1);
  else stop('deep', 64);
}
function optimized(value) {
  const result = value * 3 + 1;
  stop('optimized', result);
  return result;
}
function inlineLeaf(value) { addon.probe(value, 'inlined'); return value + 1; }
function inlineHot(value) { return inlineLeaf(value) * 3; }
process.stdout.write('ready\n');
process.stdin.once('data', async () => {
  nested(); closures(); new Point(4, 5).inspect();
  await asynchronous();
  await Promise.resolve().then(function promised() { stop('promise', true); });
  generatorCase(); recurse(90);
  if (process.argv.includes('optimized')) {
    armed = false;
    // Intrinsics run only in this cooperating fixture, never in the reader.
    eval('%NeverOptimizeFunction(stop)');
    eval('%PrepareFunctionForOptimization(optimized)');
    for (let i = 0; i < 5000; ++i) optimized(i);
    eval('%OptimizeFunctionOnNextCall(optimized)'); optimized(1);
    armed = true; optimized(14);
    addon.arm(false);
    eval('%PrepareFunctionForOptimization(inlineHot)');
    eval('%PrepareFunctionForOptimization(inlineLeaf)');
    for (let i = 0; i < 5000; ++i) inlineHot(i);
    eval('%OptimizeFunctionOnNextCall(inlineHot)'); inlineHot(1);
    addon.arm(true); inlineHot(14);
  }
  process.stdout.write(JSON.stringify({done: serial}) + '\n');
  process.exit(0);
});
