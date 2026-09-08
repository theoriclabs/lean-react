import LeanJS
import tests.ordering.Fixtures

run_meta do
  IO.FS.createDirAll "tests/ordering/.build"
  LeanJS.writeModule "tests/ordering/.build/domain.mjs" #[
    `Ordering.preview, `Ordering.Stock.fromRaw, `Ordering.Stock.reserve, `Ordering.Stock.release,
    `Ordering.Memory.quote, `Ordering.Memory.placeOrder, `Ordering.Memory.cancelOrder,
    `Ordering.Memory.confirmPayment, `Ordering.Fixtures.scenario,
    `Ordering.Fixtures.pricingCases, `Ordering.Fixtures.stockCases]
