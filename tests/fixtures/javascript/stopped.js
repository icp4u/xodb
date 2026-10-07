'use strict';
const addon = require(process.env.XODB_NODE_PROBE);
class A { constructor() { this.a = 1; } }
class B extends A { constructor() { super(); this.b = 2; } }
class C extends B {}
class Plain { constructor() { this.p = 1; } }
const changed = [new A(), new A(), new A(), new A()];
Object.setPrototypeOf(changed[0], null);
Object.setPrototypeOf(changed[1], Object.prototype);
Object.setPrototypeOf(changed[2], Plain.prototype);
changed[3].__proto__ = Plain.prototype;
const cases = [42, -7, 3.25, undefined, null, true, false, 'hi', 'héllo', 'λ 😀',
  'x'.repeat(300), [1, 'two', true], {a: 1, b: 'two'}, function named() {},
  new (class Point { constructor() { this.x = 4; this.y = 5; } })(),
  (() => { const captured = 7; return function closure() { return captured; }; })(),
  new B(), new C(), Reflect.construct(A, [], Plain),
  [1, , 3], {m: new Map(), n: 2}, {h: [1, , 2]},
  NaN, Infinity, -Infinity, [NaN, 1.5], [1.5, , 3.5],
  Buffer.alloc(200000, 120).toString('latin1'),
  Buffer.from('λ'.repeat(100000)).toString(), ...changed];
function inner(value) {
  addon.probe(value);
}
function outer(value) { inner(value); }
process.stdout.write('ready\n');
process.stdin.once('data', () => {
  for (const value of cases) outer(value);
  outer(String.fromCharCode(102, 114, 101, 115, 104));
  if (process.argv[2]) {
    if (!addon.loadLibrary(process.argv[2])) throw new Error('owned large library failed to load');
    outer(42);
  }
  process.exit(0);
});
