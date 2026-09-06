import test from "node:test";
import assert from "node:assert/strict";
import { action, pureAction, bindAction, mapAction, catchAction, runAction, duringRender } from "../../engine/runtime/actions.mjs";

test("action construction and composition are lazy; async values and errors compose", async () => {
  const log = [];
  const work = bindAction(action(() => { log.push("start"); return Promise.resolve(20n); }),
    value => action(() => { log.push("next"); return value + 2n; }));
  assert.deepEqual(log, []);
  assert.equal(await runAction(mapAction(x => x * 2n, work)), 44n);
  assert.deepEqual(log, ["start", "next"]);
  assert.equal(await runAction(catchAction(action(async () => { throw new Error("fail"); }), e => pureAction(e.message))), "fail");
  assert.equal(runAction(catchAction(action(() => { throw new Error("sync"); }), e => pureAction(e.message))), "sync");
});

test("actions reject render-phase execution and restore the phase after errors", () => {
  let count = 0;
  const work = action(() => count++);
  assert.throws(() => duringRender(() => runAction(work)), /cannot execute during render/);
  assert.equal(count, 0);
  runAction(work);
  assert.equal(count, 1);
  assert.throws(() => runAction(() => 1), /Expected a LeanReact Action/);
});

test("host service adapter defers execution and explicitly encodes async results", async () => {
  const { hostAction } = await import("../../engine/runtime/intrinsics.mjs");
  let executions = 0;
  const work = hostAction(async () => { executions++; return 42n; }, value => ({ domainValue: value }));
  assert.equal(executions, 0);
  assert.deepEqual(await runAction(work), { domainValue: 42n });
  assert.equal(executions, 1);
});
