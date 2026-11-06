// Claims under fraud investigation are visible to senior adjusters only.
// A forbid always overrides a permit, so no future permit can reopen them.
forbid (
  principal,
  action == ClaimsAssist::Action::"ReadClaim",
  resource is ClaimsAssist::Claim
)
when {
  resource.underInvestigation &&
  !(context.token.population == "staff" &&
    context.token.role == "claims-senior-adjuster")
};
