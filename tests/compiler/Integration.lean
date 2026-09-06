-- A companion driver using the parent's declarations and current bridge unchanged.
import Examples.ReactCompiler
import Examples.Tickets.Components

run_meta do
  let exports := #[
    `Examples.Tickets.App, `Examples.Tickets.Counter, `Examples.Tickets.TicketList,
    `Examples.Tickets.Card, `Examples.Tickets.Editor, `Examples.Tickets.PageEditor,
    `Examples.Tickets.initialTickets, `Examples.Tickets.Title.parse,
    `Examples.Tickets.TitleError.message, `Examples.Tickets.applySave,
    `Examples.Tickets.countOpen, `Examples.Tickets.renderTitles]
  IO.FS.createDirAll "tests/compiler/integration/generated"
  LeanJS.writeModule "tests/compiler/integration/generated/tickets-subset.mjs" exports
    Examples.reactOptions
