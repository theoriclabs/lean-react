# Let an earlier choice constrain a later one

[All guides](README.md) · Checked example: `Choices` in [GuideExamples.lean](GuideExamples.lean)

A shipping form has a country dropdown and a service dropdown. Both values are individually valid. Their combination may still be unavailable.

Filtering the second dropdown helps the user, but a restored draft or delayed event can still contain an old service. Put the relationship in the accepted model as well.

```lean
abbrev AvailableService (country : Country) :=
  { service : Service // serves country service }

abbrev Shipping := (country : Country) × AvailableService country
```

The second value carries evidence that it is allowed for the first. This is a dependent pair. The `Choices` namespace in [GuideExamples.lean](GuideExamples.lean) supplies two countries, two services, a decision procedure, and a runtime checker. Express delivery is accepted in the north and rejected in the south.

**Pick the right representation**

A subtype works well when services have common identities and availability is a rule about them. A computed type family is useful when the required payload itself changes. For example, pickup may need a store selection while international delivery needs customs details. Both approaches express a dependency, but solve slightly different problems.

**Use this when**

An earlier selection changes valid options or required data: country and service, product and compatible accessory, account type and tax details, or chart type and configuration fields. The relationship should matter to code beyond the dropdown itself.

**Choose something simpler when**

The options are independent, or filtering is only a display preference. For a one-off form, validating the pair in one function may be enough. Return a checked value from that function if several later operations rely on the relationship.

**Handle changes and external input**

1. Store the raw selection as a draft while the user edits.
2. Check the country/service pair before constructing the accepted value.
3. When the country changes, clear the service or check whether it remains valid. Make that policy explicit.
4. Parse restored drafts and server responses through the same relationship check.

A proof about yesterday's availability table does not establish today's availability. If the rules change, include their revision in the relevant context or validate against the current policy at the operation boundary. The example's `serves` function is deliberately fixed.

**What becomes smaller**

If four countries allow 3, 2, 2, and 1 services, the dependent choice has eight configurations. Two independent four-way fields admit sixteen. The larger finite example is in [StateSpaceComposition.lean](../StateSpaceComposition.lean).

**Composition and checks**

Several later choices can depend on the same country. If they also depend on each other, use a [relation on the combination](04-relational-refinements.md) or a [chain of contexts](09-context-chains.md). Do not assume that two services valid individually are necessarily compatible together.

Check changing the first choice while retaining the second, decoding an unsupported pair, and refreshing the policy. Keep an explicit “no available options” UI when a branch is empty. A type can represent that absence accurately; it does not choose the product behavior for you. See [dependent pairs](https://lean-lang.org/doc/reference/latest/Basic-Types/Tuples/) and [subtypes](https://lean-lang.org/doc/reference/latest/Basic-Types/Subtypes/).
