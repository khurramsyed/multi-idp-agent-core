// Brokers read policies that belong to their own agency's customers.
permit (
  principal,
  action == ClaimsAssist::Action::"ReadPolicy",
  resource is ClaimsAssist::Policy
)
when {
  context.token.population == "broker" &&
  context.token.agency_id != "" &&
  resource.agencyId == context.token.agency_id
};
