import Examples.ReactCompiler
import Examples.Tickets.Components
import Examples.Tickets.Queries

run_meta do
  IO.FS.createDirAll "examples/generated"
  LeanJS.writeModule "examples/generated/tickets.mjs" #[
    `Examples.Tickets.App,
    `Examples.Tickets.memoryService,
    `Examples.Tickets.Workspace,
    `Examples.Tickets.Counter,
    `Examples.Tickets.TicketList,
    `Examples.Tickets.Card,
    `Examples.Tickets.Editor,
    `Examples.Tickets.PageEditor,
    `Examples.Tickets.initialTickets,
    `Examples.Tickets.Title.parse,
    `Examples.Tickets.TitleError.message,
    `Examples.Tickets.applySave,
    `Examples.Tickets.countOpen,
    `Examples.Tickets.renderTitles,
    `Examples.Tickets.previewTitles
  ] Examples.reactOptions
