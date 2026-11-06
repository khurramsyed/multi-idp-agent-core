// Adjusters read policies in their own region.
permit (
  principal,
  action == ClaimsAssist::Action::"ReadPolicy",
  resource is ClaimsAssist::Policy
)
when {
  context.token.population == "staff" &&
  ["claims-adjuster", "claims-senior-adjuster"].contains(context.token.role) &&
  resource.region == context.token.region
};
