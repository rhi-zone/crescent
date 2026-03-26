// Node.js JSON.parse benchmarks for comparison with Lua tiers.
// Run: node docs/perf/json_node.js
// See: docs/perf/log.md for recorded results and analysis.

// Single-object: warm vs cold shape cache
const SRC = '{"name":"Alice","age":30,"city":"NY","zip":10001,"active":true}';
const N = 500000;

for (let i = 0; i < 2000; i++) JSON.parse(SRC);

let t0 = performance.now();
for (let i = 0; i < N; i++) JSON.parse(SRC);
const ns_warm = (performance.now() - t0) * 1e6 / N;
console.log(`single object, warm shape:  ${ns_warm.toFixed(1)} ns  →  ${(SRC.length/(ns_warm*1e-9)/1e6).toFixed(0)} MB/s`);

// Cold: unique shape per call
const srcs = [];
for (let i = 0; i < N; i++)
    srcs.push(`{"k${i}":"v","name":"Alice","age":30,"city":"NY","zip":${i},"active":true}`);
for (let i = 0; i < 200; i++) JSON.parse(srcs[i]);
t0 = performance.now();
for (let i = 0; i < N; i++) JSON.parse(srcs[i]);
const ns_cold = (performance.now() - t0) * 1e6 / N;
console.log(`single object, cold shape:  ${ns_cold.toFixed(1)} ns  (shape cache speedup: ${(ns_cold/ns_warm).toFixed(1)}x)`);

// 1000-object collect loop (fair comparison with json_collect.lua)
const names  = ["Alice","Bob","Carol","Dave","Eve","Frank","Grace","Hank","Iris","Jack"];
const cities = ["NY","LA","SF","Chicago","Houston","Phoenix","Dallas","Austin","Seattle","Denver"];
const lines  = [];
for (let i = 0; i < 1000; i++) {
    lines.push(`{"name":"${names[i%10]}","age":${20+i%50},"city":"${cities[i%10]}","zip":${10000+i},"active":${i%3===0}}`);
}
const TOTAL = lines.reduce((s,l) => s+l.length, 0);
for (let j = 0; j < 10; j++) for (let i = 0; i < 1000; i++) JSON.parse(lines[i]);

const M = 2000;
t0 = performance.now();
for (let j = 0; j < M; j++) {
    const res = [];
    for (let i = 0; i < 1000; i++) res.push(JSON.parse(lines[i]));
}
const us = (performance.now() - t0) * 1000 / M;
console.log(`1000-object collect loop:   ${us.toFixed(1)} µs/batch  →  ${(TOTAL/(us*1e-6)/1e6).toFixed(0)} MB/s`);
