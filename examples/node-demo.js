'use strict';
// Run with scripts/demo-node, which builds this owned native probe with DWARF.
const addon = require(process.env.XODB_NODE_PROBE);
class Point {
  constructor(x, y) { this.x = x; this.y = y; }
}
function inspect(value, round) {
  // Keep both parameters in context storage for the JS pane demonstration.
  const retained = () => [value, round];
  addon.probe(value);
  return retained();
}
function tick(round) {
  const values = [round, 3.25, 'héllo λ 😀', [1, 'two', true],
    {answer: 42, message: 'hi'}, new Point(round, 5), function named() {}];
  inspect(values[round % values.length], round);
}
process.stdout.write(process.pid + '\n');
let round = 0;
setInterval(() => tick(round++), 50);
