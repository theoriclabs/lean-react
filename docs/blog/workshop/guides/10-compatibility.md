# Require evidence that two choices work together

[All guides](README.md) · Checked example: `Compatibility` in [GuideExamples.lean](GuideExamples.lean)

A checkout offers two payment providers and two currencies. The card provider supports both currencies. The bank provider supports only dollars. Two independent dropdowns permit a combination the integration cannot process.

The useful relationship is compatibility. An operation should require evidence of that relationship.

**The model**

The example uses a deliberately small, fictional support matrix:

```lean
def supported : Provider → Currency → Bool
  | .card, _ => true
  | .bank, .usd => true
  | .bank, .eur => false

class Supports (provider : Provider) (currency : Currency) : Prop where
  allowed : supported provider currency = true
```

The class is evidence, not a payment implementation. Instances supply evidence for the three allowed pairs. A route-description function requires it:

```lean
def prepare (provider : Provider) (currency : Currency)
    [Supports provider currency] : String :=
  match provider, currency with
  | .card, .usd => "card/USD"
  | .card, .eur => "card/EUR"
  | .bank, _ => "bank/USD"
```

Calling `prepare .card .eur` works. Calling `prepare .bank .eur` cannot find the required evidence. The apparent bank catch-all does not make the unsupported pair callable through this contract.

The class includes a proof of the support rule. It is stronger than an empty marker class that someone could instantiate for any pair. [Type classes in Lean](https://lean-lang.org/doc/reference/latest/Type-Classes/)

**Use this when**

Use compatibility indices for integrations with restricted combinations: an export format and feature, a storage backend and operation, or a provider and payment method. Type classes are useful when supported combinations are known while writing code and evidence should be supplied automatically.

Choose an explicit checked function for options driven by runtime configuration. An ordinary predicate and a subtype may communicate that boundary more directly. Use a [dependent choice](02-dependent-choices.md) when the main task is constructing a UI selection with only the permitted options.

**Runtime choices still need a runtime check**

Class search does not wait for the customer to select a currency. A variable holding a runtime choice needs a different path:

```lean
def prepareChoice (provider : Provider) (currency : Currency)
    : Except String String :=
  if h : supported provider currency = true then
    letI : Supports provider currency := ⟨h⟩
    .ok (prepare provider currency)
  else .error "Choose a supported provider and currency."
```

The check establishes the rule. `letI` makes that evidence available locally as a class instance. The rest of the function can now use the same constrained API as a statically known caller.

This separates two useful jobs: validate a dynamic selection at the edge, then require compatible inputs in the code that depends on them.

**Adopt it at the operation boundary**

Write the support matrix in one place. Make the relevant operation require its evidence. Filter the UI using the same rule, and still validate incoming selections. Disabled options are a convenience; they are not validation of restored drafts or external input.

If support depends on account settings or a policy version, include that context in the relation. A global instance for a pair is the wrong model when the pair works for one account and fails for another. Explicit policy values are often simpler in that case.

The example has four possible pairs and accepts three. It describes routes only. It does not contact a provider or prove that a payment will succeed.

**What to check**

Check every supported pair, a statically rejected pair, and both runtime branches. Also test policy changes if the real matrix is mutable. Compatibility makes a request eligible for an operation; network failures and business declines still need ordinary result states.
