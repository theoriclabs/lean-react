import LeanJS
import Examples.Tickets.Domain
import Examples.Tickets.Queries

run_meta do
  IO.FS.createDirAll "examples/generated"
  LeanJS.writeModule "examples/generated/domain.mjs" #[
    `Ontology.EntityId.parse,
    `Examples.Tickets.seed,
    `Examples.Tickets.Title.parse,
    `Examples.Tickets.TitleError.message,
    `Examples.Tickets.Status.parse,
    `Examples.Tickets.applySave,
    `Examples.Tickets.countOpen,
    `Examples.Tickets.renderTitles,
    `Examples.Tickets.previewTitles
  ]
