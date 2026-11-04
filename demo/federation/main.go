// federation: the PoC's Trust Controller, self-hosted. It stands in for Raidiam Connect, built on
// github.com/MichaelFraser99/go-openid-federation. One process, one HTTPS origin (FED_BASE_URL), serving:
//
//	<base>/anchor                              trust anchor   (.well-known, fetch, list, resolve)
//	<base>/authority                           the authority  (.well-known, fetch, list, resolve), authority_hints = anchor
//	<base>/openid_relying_party/<statement id> federation-managed entities' Entity Configurations, hosted and signed here
//	<base>/keystore/<org>/<statement id>/application.jwks
//	                                           the keys certified for a statement (x5c), its jwks_uri
//	<base>/directory[/participants]            the directory's public export: the organisation, its authorisation
//	                                           server (PingFederate) and its role claims
//	<base>/api/...                             the slice of Raidiam's admin API the marketplace and rig.sh use: software
//	                                           statements, certificates (CSR -> certificate), authority claims.
//	                                           Unauthenticated - a PoC; port 9444 serves the same API in plain HTTP on localhost
//
// The authority vouches for every Active statement with a certified key (self-hosted: its ClientId; federation-managed:
// <base>/openid_relying_party/<id>) and for the authorisation server, whose keys it reads from the issuer's own Entity
// Configuration. Its metadata_policy for each is built the way Raidiam builds it: value policies from the statement's
// fields, the SPIFFE binding from AdditionalSoftwareMetadata, capabilities from its roles, plus any
// FederationMetadataPolicy the statement carries (an extension: Raidiam derives those from ApiResources).
package main

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"log/slog"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/MichaelFraser99/go-jose/jwa"
	"github.com/MichaelFraser99/go-jose/jwk"
	"github.com/MichaelFraser99/go-jose/jws"
	josemodel "github.com/MichaelFraser99/go-jose/model"
	"github.com/MichaelFraser99/go-openid-federation/client"
	"github.com/MichaelFraser99/go-openid-federation/model"
	"github.com/MichaelFraser99/go-openid-federation/server"
)

const federationManaged = "openid_entity_federation_managed"

// ── state ───────────────────────────────────────────────────────────────────────────────────────

type certificate struct {
	ID      string         `json:"id"`
	Type    string         `json:"type"`
	Status  string         `json:"status"`
	JWK     map[string]any `json:"jwk"` // public, with kid and x5c
	PEM     string         `json:"pem"`
	Created time.Time      `json:"created"`
}

type claim struct {
	ID                  string `json:"SoftwareAuthorityClaimId"`
	OrgClaimID          string `json:"OrganisationAuthorisationDomainRoleClaimID"`
	Role                string `json:"Role"`
	Status              string `json:"Status"`
	AuthorisationDomain string `json:"AuthorisationDomain"`
}

type statement struct {
	Record       map[string]any  `json:"record"`
	EntityKey    map[string]any  `json:"entity_key,omitempty"` // federation-managed: the key it is hosted with
	Certificates []*certificate  `json:"certificates"`
	Claims       []*claim        `json:"claims"`
	ExtraPolicy  json.RawMessage `json:"extra_policy,omitempty"`
}

type authServer struct {
	Record  map[string]any  `json:"record"`
	JWKs    json.RawMessage `json:"jwks,omitempty"` // from the issuer's Entity Configuration
	Fetched time.Time       `json:"fetched"`
	Error   string          `json:"error,omitempty"`
}

type state struct {
	AnchorKey    map[string]any          `json:"anchor_key"`
	AuthorityKey map[string]any          `json:"authority_key"`
	CAKey        map[string]any          `json:"ca_key"` // the directory's certificate authority (rtssigning certificates)
	CACert       string                  `json:"ca_cert"`
	Statements   map[string]*statement   `json:"statements"`
	AuthServers  map[string]*authServer  `json:"authorisation_servers"`
}

// ── roles: what each grants, as Raidiam's role claims carry it ─────────────────────────────────

var roleCapabilities = map[string][]string{
	"cba.accounts.reader":    {"accounts_read"},
	"cba.payments.initiator": {"payment_initiation"},
	"Payments-Execution":     {"payment_initiation", "accounts_write"},
	"cba.supplier.reader":    {"supplier_invoice", "supplier_payment"},
	"cba.oidc.participant":   {"openid_credential"},
	"cba.banking.provider":   {},
	"cba.group.member":       {},
	"cba.au.member":          {},
}

func roleNames() []string {
	names := make([]string, 0, len(roleCapabilities))
	for r := range roleCapabilities {
		names = append(names, r)
	}
	sort.Strings(names)
	return names
}

// orgClaimID is a stable identifier for an organisation's claim on a role.
func orgClaimID(role string) string { return "orgclaim-" + strings.ToLower(strings.ReplaceAll(role, ".", "-")) }

// agentGrants: what Raidiam's policy gives every agent (a statement with a SPIFFE binding).
var agentGrants = []any{"client_credentials", "urn:ietf:params:oauth:grant-type:token-exchange",
	"urn:openid:params:grant-type:ciba", "urn:ietf:params:oauth:grant-type:device_code"}

// ── keys ────────────────────────────────────────────────────────────────────────────────────────

func newKey() (map[string]any, error) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	j, err := jwk.PrivateJwk(priv)
	if err != nil {
		return nil, err
	}
	return *j, nil
}

func signerFor(private map[string]any) (model.SignerConfiguration, map[string]any, error) {
	key, err := jwk.PrivateFromJwk(private)
	if err != nil {
		return model.SignerConfiguration{}, nil, err
	}
	s, err := jws.GetSignerFromPrivateKey(jwa.ES256, key)
	if err != nil {
		return model.SignerConfiguration{}, nil, err
	}
	pub, err := jwk.PublicJwk(s.Public())
	if err != nil {
		return model.SignerConfiguration{}, nil, err
	}
	(*pub)["alg"] = "ES256"
	return model.SignerConfiguration{Signer: s, KeyID: (*pub)["kid"].(string), Algorithm: "ES256"}, *pub, nil
}

func uuid() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

// ── the federation ──────────────────────────────────────────────────────────────────────────────

type federation struct {
	base, org, orgName, dataDir string
	httpClient                  *http.Client
	logger                      *slog.Logger

	mu       sync.RWMutex
	st       state
	routes   map[string]http.Handler
	anchorID model.EntityIdentifier
	authID   model.EntityIdentifier
	anchor   josemodel.Jwks
}

func (f *federation) managedID(ssid string) string { return f.base + "/openid_relying_party/" + ssid }
func (f *federation) keystoreURL(ssid string) string {
	return fmt.Sprintf("%s/keystore/%s/%s/application.jwks", f.base, f.org, ssid)
}

func str(m map[string]any, k string) string {
	if v, ok := m[k].(string); ok {
		return v
	}
	return ""
}

func (f *federation) load() error {
	b, err := os.ReadFile(filepath.Join(f.dataDir, "state.json"))
	if err == nil {
		if err := json.Unmarshal(b, &f.st); err != nil {
			return err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if f.st.Statements == nil {
		f.st.Statements = map[string]*statement{}
	}
	if f.st.AuthServers == nil {
		f.st.AuthServers = map[string]*authServer{}
	}
	for _, k := range []*map[string]any{&f.st.AnchorKey, &f.st.AuthorityKey} {
		if *k == nil {
			if *k, err = newKey(); err != nil {
				return err
			}
		}
	}
	if f.st.CAKey == nil {
		if err := f.newCA(); err != nil {
			return err
		}
	}
	// The authorisation server named in the environment (PingFederate), created or brought up to date.
	if id := os.Getenv("FED_AS_ID"); id != "" {
		as := f.st.AuthServers[id]
		if as == nil {
			as = &authServer{Record: map[string]any{}}
			f.st.AuthServers[id] = as
		}
		issuer := strings.TrimSuffix(os.Getenv("FED_AS_ISSUER"), "/")
		if str(as.Record, "Issuer") != issuer {
			as.JWKs, as.Fetched = nil, time.Time{}
		}
		as.Record["AuthorisationServerId"] = id
		as.Record["OrganisationId"] = f.org
		as.Record["Issuer"] = issuer
		as.Record["OpenIDDiscoveryDocument"] = issuer + "/.well-known/openid-configuration"
		as.Record["CustomerFriendlyName"] = envOr("FED_AS_NAME", "PingFederate (PoC)")
		as.Record["CustomerFriendlyDescription"] = "The PoC's authorisation server"
		as.Record["Status"] = "Active"
		as.Record["AutoRegistrationSupported"] = true
		as.Record["SupportsCiba"] = true
		as.Record["ApiResources"] = []any{}
	}
	return f.save()
}

func (f *federation) newCA() error {
	k, err := newKey()
	if err != nil {
		return err
	}
	priv, _ := jwk.PrivateFromJwk(k)
	signer := priv.(crypto.Signer)
	tpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: "PoC directory CA", Organization: []string{"PoC Trust Framework"}},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().AddDate(10, 0, 0),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, signer.Public(), signer)
	if err != nil {
		return err
	}
	f.st.CAKey, f.st.CACert = k, string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
	return nil
}

func (f *federation) save() error {
	b, _ := json.MarshalIndent(f.st, "", "  ")
	tmp := filepath.Join(f.dataDir, "state.json.tmp")
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(f.dataDir, "state.json"))
}

func (f *federation) common() model.Configuration {
	return model.Configuration{HttpClient: f.httpClient, Logger: f.logger}
}

func mount(cfg model.ServerConfiguration) http.Handler {
	mux := http.NewServeMux()
	server.NewServer(cfg).Configure(mux)
	return mux
}

// build (re)creates the entities' handlers. The authority reads its subordinates live (retriever), so only a change
// to a federation-managed statement needs a rebuild.
func (f *federation) build() error {
	anchorSigner, anchorPub, err := signerFor(f.st.AnchorKey)
	if err != nil {
		return err
	}
	authSigner, authPub, err := signerFor(f.st.AuthorityKey)
	if err != nil {
		return err
	}
	f.anchorID = model.EntityIdentifier(f.base + "/anchor")
	f.authID = model.EntityIdentifier(f.base + "/authority")
	f.anchor = josemodel.Jwks{Keys: []map[string]any{anchorPub}}
	anchors := map[model.EntityIdentifier]josemodel.Jwks{f.anchorID: f.anchor}
	routes := map[string]http.Handler{}

	anchorInt := &model.IntermediateConfiguration{SubordinateStatementLifetime: time.Hour}
	anchorInt.AddSubordinate(f.authID, &model.SubordinateConfiguration{JWKs: josemodel.Jwks{Keys: []map[string]any{authPub}}})
	acfg := f.common()
	acfg.TrustAnchors = anchors
	routes["/anchor"] = mount(model.ServerConfiguration{
		Configuration: acfg, SignerConfiguration: anchorSigner, EntityIdentifier: f.anchorID,
		EntityConfigurationLifetime: 24 * time.Hour, IntermediateConfiguration: anchorInt,
		EntityConfiguration: model.EntityStatement{Metadata: &model.Metadata{FederationMetadata: &model.FederationMetadata{
			"organization_name": f.orgName + " Trust Anchor (PoC)"}}},
	})

	authCfg := f.common()
	authCfg.TrustAnchors = anchors
	routes["/authority"] = mount(model.ServerConfiguration{
		Configuration: authCfg, SignerConfiguration: authSigner, EntityIdentifier: f.authID,
		AuthorityHints:              []model.EntityIdentifier{f.anchorID},
		EntityConfigurationLifetime: 24 * time.Hour,
		IntermediateConfiguration:   &model.IntermediateConfiguration{SubordinateStatementLifetime: 20 * time.Minute},
		MetadataRetriever:           retriever{f},
		EntityConfiguration: model.EntityStatement{Metadata: &model.Metadata{FederationMetadata: &model.FederationMetadata{
			"organization_name": f.orgName + " Authority (PoC)"}}},
	})

	for ssid, s := range f.st.Statements {
		if s.EntityKey == nil {
			continue
		}
		signer, _, err := signerFor(s.EntityKey)
		if err != nil {
			return err
		}
		var md model.Metadata
		if err := json.Unmarshal(f.hostedMetadata(ssid, s), &md); err != nil {
			return fmt.Errorf("statement %s metadata: %w", ssid, err)
		}
		routes["/openid_relying_party/"+ssid] = mount(model.ServerConfiguration{
			Configuration: f.common(), SignerConfiguration: signer, EntityIdentifier: model.EntityIdentifier(f.managedID(ssid)),
			AuthorityHints:              []model.EntityIdentifier{f.authID},
			EntityConfigurationLifetime: time.Hour,
			EntityConfiguration:         model.EntityStatement{Metadata: &md},
		})
	}
	f.routes = routes
	return nil
}

// hostedMetadata: the Entity Configuration Raidiam writes for a federation-managed statement.
func (f *federation) hostedMetadata(ssid string, s *statement) []byte {
	r := s.Record
	rp := map[string]any{
		"client_id":                 f.managedID(ssid),
		"client_name":               str(r, "ClientName"),
		"client_description":        str(r, "Description"),
		"client_registration_types": []string{"automatic"},
		"jwks_uri":                  f.keystoreURL(ssid),
		"redirect_uris":             r["RedirectUri"],
		"software_id":               ssid,
		"software_version":          str(r, "SoftwareVersion"),
		"organisation_id":           f.org,
		"subject_type":              "public",
	}
	for k, field := range map[string]string{"client_uri": "ClientUri", "logo_uri": "LogoUri"} {
		if v := str(r, field); v != "" {
			rp[k] = v
		}
	}
	if rp["redirect_uris"] == nil {
		rp["redirect_uris"] = []string{f.managedID(ssid) + "/callback"}
	}
	b, _ := json.Marshal(map[string]any{
		"federation_entity":    map[string]any{"organization_name": f.orgName},
		"openid_relying_party": rp,
	})
	return b
}

// policy: the authority's metadata_policy for a statement, as Raidiam builds it.
func (f *federation) policy(ssid string, s *statement) map[string]map[string]map[string]any {
	r := s.Record
	rp := map[string]map[string]any{}
	set := func(param string, v any) { rp[param] = map[string]any{"value": v} }
	for param, field := range map[string]string{"client_name": "ClientName", "client_uri": "ClientUri",
		"logo_uri": "LogoUri", "software_version": "SoftwareVersion"} {
		if v := str(r, field); v != "" {
			set(param, v)
		}
	}
	if v, ok := r["RedirectUri"].([]any); ok && len(v) > 0 {
		set("redirect_uris", v)
	}
	if len(activeCerts(s)) > 0 {
		set("jwks_uri", f.keystoreURL(ssid))
	}
	// The SPIFFE binding (AdditionalSoftwareMetadata): set where the statement carries it, removed where it does not,
	// so no leaf can claim a binding for itself.
	asm := map[string]any{}
	if raw := str(r, "AdditionalSoftwareMetadata"); raw != "" {
		_ = json.Unmarshal([]byte(raw), &asm)
	}
	for _, k := range []string{"spiffe_id", "spiffe_trust_domain", "spiffe_bundle_endpoint", "spiffe_bundle_format", "client_attesters"} {
		set(k, asm[k])
	}
	if asm["spiffe_id"] != nil {
		set("grant_types", agentGrants)
		set("backchannel_token_delivery_mode", "poll")
	}
	// Capabilities from the roles it holds.
	var types []any
	for _, c := range s.Claims {
		if c.Status != "Active" {
			continue
		}
		for _, t := range roleCapabilities[c.Role] {
			if !slices.Contains(types, any(t)) {
				types = append(types, t)
			}
		}
	}
	if len(types) > 0 {
		set("authorization_details_types", types)
	}
	out := map[string]map[string]map[string]any{"openid_relying_party": rp}
	// The extension: further policy, entity type by entity type, parameter by parameter (it replaces ours).
	var extra map[string]map[string]map[string]any
	if len(s.ExtraPolicy) > 0 && json.Unmarshal(s.ExtraPolicy, &extra) == nil {
		for et, params := range extra {
			if out[et] == nil {
				out[et] = map[string]map[string]any{}
			}
			for p, ops := range params {
				out[et][p] = ops
			}
		}
	}
	return out
}

func activeCerts(s *statement) []*certificate {
	var out []*certificate
	for _, c := range s.Certificates {
		if c.Status == "Active" {
			out = append(out, c)
		}
	}
	return out
}

// subordinate: the authority's view of one entity it vouches for, or nil.
func (f *federation) subordinate(id model.EntityIdentifier) (*model.SubordinateConfiguration, []string) {
	for ssid, s := range f.st.Statements {
		if str(s.Record, "Status") != "Active" {
			continue
		}
		entityID := str(s.Record, "ClientId")
		if string(id) != entityID {
			continue
		}
		sub := &model.SubordinateConfiguration{}
		if s.EntityKey != nil {
			_, pub, _ := signerFor(s.EntityKey)
			sub.JWKs.Keys = []map[string]any{pub}
		} else {
			for _, c := range activeCerts(s) {
				sub.JWKs.Keys = append(sub.JWKs.Keys, c.JWK)
			}
			if len(sub.JWKs.Keys) == 0 {
				return nil, nil // nothing certified: nothing to vouch for
			}
		}
		pol := f.policy(ssid, s)
		b, _ := json.Marshal(pol)
		if err := json.Unmarshal(b, &sub.Policies); err != nil {
			f.logger.Error("statement policy does not parse", "statement", ssid, "error", err)
			return nil, nil
		}
		types := []string{"federation_entity", "openid_relying_party"}
		for et, params := range pol {
			if len(params) > 0 && !slices.Contains(types, et) {
				types = append(types, et)
			}
		}
		return sub, types
	}
	for _, as := range f.st.AuthServers {
		if str(as.Record, "Issuer") != string(id) || str(as.Record, "Status") != "Active" || len(as.JWKs) == 0 {
			continue
		}
		sub := &model.SubordinateConfiguration{}
		if err := json.Unmarshal(as.JWKs, &sub.JWKs); err != nil {
			return nil, nil
		}
		b, _ := json.Marshal(map[string]any{"openid_provider": map[string]any{
			"issuer":      map[string]any{"value": string(id)},
			"grant_types": map[string]any{"add": []any{"urn:openid:params:grant-type:ciba"}},
		}})
		_ = json.Unmarshal(b, &sub.Policies)
		return sub, []string{"federation_entity", "openid_provider", "oauth_authorization_server"}
	}
	return nil, nil
}

func (f *federation) subjects() []model.EntityIdentifier {
	var ids []model.EntityIdentifier
	for _, s := range f.st.Statements {
		ids = append(ids, model.EntityIdentifier(str(s.Record, "ClientId")))
	}
	for _, as := range f.st.AuthServers {
		ids = append(ids, model.EntityIdentifier(str(as.Record, "Issuer")))
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	return slices.Compact(ids)
}

// retriever: the authority's subordinates, read from the state on every request.
type retriever struct{ f *federation }

func (r retriever) GetSubordinate(_ context.Context, id model.EntityIdentifier) (*model.SubordinateConfiguration, error) {
	r.f.mu.RLock()
	defer r.f.mu.RUnlock()
	sub, _ := r.f.subordinate(id)
	if sub == nil {
		return nil, model.NewNotFoundError("the authority does not vouch for this entity")
	}
	return sub, nil
}

func (r retriever) GetSubordinates(_ context.Context) (map[model.EntityIdentifier]*model.SubordinateConfiguration, error) {
	r.f.mu.RLock()
	defer r.f.mu.RUnlock()
	out := map[model.EntityIdentifier]*model.SubordinateConfiguration{}
	for _, id := range r.f.subjects() {
		if sub, _ := r.f.subordinate(id); sub != nil {
			out[id] = sub
		}
	}
	return out, nil
}

func (r retriever) GetSubordinateSigners(context.Context) ([]model.SignerConfiguration, error) { return nil, nil }

func (r retriever) ListSubordinates(_ context.Context, filter model.SubordinateListingFilter) ([]model.EntityIdentifier, error) {
	r.f.mu.RLock()
	defer r.f.mu.RUnlock()
	if (filter.Intermediate != nil && *filter.Intermediate) || (filter.TrustMarked != nil && *filter.TrustMarked) || filter.TrustMarkType != nil {
		return []model.EntityIdentifier{}, nil // none is an intermediate, none carries a trust mark
	}
	out := []model.EntityIdentifier{}
	for _, id := range r.f.subjects() {
		sub, types := r.f.subordinate(id)
		if sub == nil {
			continue
		}
		match := len(filter.EntityTypes) == 0
		for _, t := range filter.EntityTypes {
			match = match || slices.Contains(types, t)
		}
		if match {
			out = append(out, id)
		}
	}
	return out, nil
}

// refreshAuthServers keeps each authorisation server's keys current from its own Entity Configuration: soon after
// it comes up, then every ten minutes.
func (f *federation) refreshAuthServers(ctx context.Context) {
	for {
		f.mu.RLock()
		due := map[string]string{}
		for id, as := range f.st.AuthServers {
			if len(as.JWKs) == 0 || time.Since(as.Fetched) > 10*time.Minute {
				due[id] = str(as.Record, "Issuer")
			}
		}
		f.mu.RUnlock()
		for id, issuer := range due {
			c, cancel := context.WithTimeout(ctx, 10*time.Second)
			jwks, err := f.selfSignedJWKS(c, issuer)
			cancel()
			f.mu.Lock()
			as := f.st.AuthServers[id]
			if err != nil {
				if as.Error != err.Error() {
					f.logger.Info("authorisation server's Entity Configuration not usable yet", "issuer", issuer, "error", err)
				}
				as.Error = err.Error()
			} else {
				if string(as.JWKs) != string(jwks) {
					f.logger.Info("authorisation server's keys taken from its Entity Configuration", "issuer", issuer)
				}
				as.JWKs, as.Fetched, as.Error = jwks, time.Now().UTC(), ""
			}
			_ = f.save()
			f.mu.Unlock()
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(15 * time.Second):
		}
	}
}

func (f *federation) selfSignedJWKS(ctx context.Context, entityID string) (json.RawMessage, error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimSuffix(entityID, "/")+"/.well-known/openid-federation", nil)
	res, err := f.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode != 200 {
		return nil, fmt.Errorf("entity configuration: HTTP %d", res.StatusCode)
	}
	parts := strings.Split(strings.TrimSpace(string(body)), ".")
	if len(parts) != 3 {
		return nil, errors.New("entity configuration is not a compact JWS")
	}
	payload, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(parts[1], "="))
	if err != nil {
		return nil, err
	}
	var claims struct {
		Sub  string          `json:"sub"`
		JWKs json.RawMessage `json:"jwks"`
	}
	if err := json.Unmarshal(payload, &claims); err != nil {
		return nil, err
	}
	if strings.TrimSuffix(claims.Sub, "/") != strings.TrimSuffix(entityID, "/") {
		return nil, fmt.Errorf("entity configuration is for %q", claims.Sub)
	}
	var set josemodel.Jwks
	if err := json.Unmarshal(claims.JWKs, &set); err != nil {
		return nil, err
	}
	var keys []crypto.PublicKey
	for _, k := range set.Keys {
		if pk, err := jwk.PublicFromJwk(k); err == nil {
			keys = append(keys, pk)
		}
	}
	if _, _, err := jws.Verify(ctx, string(body), func() ([]crypto.PublicKey, error) { return keys, nil }, nil); err != nil {
		return nil, fmt.Errorf("entity configuration is not signed by its own jwks: %w", err)
	}
	return claims.JWKs, nil
}

func (f *federation) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.RLock()
	routes := f.routes
	f.mu.RUnlock()
	best := ""
	for p := range routes {
		if (r.URL.Path == p || strings.HasPrefix(r.URL.Path, p+"/")) && len(p) > len(best) {
			best = p
		}
	}
	if best == "" {
		http.NotFound(w, r)
		return
	}
	http.StripPrefix(best, routes[best]).ServeHTTP(w, r)
}

// ── the directory: public export, keystore, admin API ───────────────────────────────────────────

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

func fail(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]any{"errors": []map[string]string{{"code": http.StatusText(status), "title": msg}}})
}

// mutate runs a change under the lock, persists it and rebuilds the handlers.
func (f *federation) mutate(change func() error) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := change(); err != nil {
		return err
	}
	if err := f.build(); err != nil {
		return err
	}
	return f.save()
}

func (f *federation) statementView(ssid string, s *statement) map[string]any {
	out := map[string]any{}
	for k, v := range s.Record {
		out[k] = v
	}
	return out
}

func (f *federation) certView(c *certificate) map[string]any {
	out := map[string]any{
		"CertificateOrKeyId": c.ID, "CertificateOrKeyType": c.Type, "keyType": c.Type, "Status": c.Status,
		"kid": c.JWK["kid"], "kty": c.JWK["kty"], "CreatedAt": c.Created, "PemCertificate": c.PEM,
	}
	for _, k := range []string{"n", "e", "x", "y", "crv"} {
		if v, ok := c.JWK[k]; ok {
			out[k] = v
		}
	}
	return out
}

func (f *federation) orgClaims() []map[string]any {
	var out []map[string]any
	for _, role := range roleNames() {
		var md []map[string]any
		if caps := roleCapabilities[role]; len(caps) > 0 {
			md = append(md, map[string]any{"EntityType": "openid_relying_party", "ClaimName": "authorization_details_types",
				"PolicyOperator": "value", "Values": caps})
		}
		out = append(out, map[string]any{
			"OrganisationAuthorityClaimId": orgClaimID(role), "AuthorisationDomainRoleIdentifier": orgClaimID(role),
			"AuthorisationDomain": "CBA-Global", "Role": role, "Status": "Active", "RoleType": "Federation", "Metadata": md,
		})
	}
	return out
}

func (f *federation) issue(csrPEM []byte, certType string) (*certificate, error) {
	block, _ := pem.Decode(csrPEM)
	if block == nil {
		return nil, errors.New("the body is not a PEM CSR")
	}
	csr, err := x509.ParseCertificateRequest(block.Bytes)
	if err != nil {
		return nil, err
	}
	if err := csr.CheckSignature(); err != nil {
		return nil, fmt.Errorf("the CSR's signature does not verify: %w", err)
	}
	caBlock, _ := pem.Decode([]byte(f.st.CACert))
	ca, err := x509.ParseCertificate(caBlock.Bytes)
	if err != nil {
		return nil, err
	}
	caPriv, err := jwk.PrivateFromJwk(f.st.CAKey)
	if err != nil {
		return nil, err
	}
	tpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: csr.Subject,
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().AddDate(1, 0, 0),
		KeyUsage: x509.KeyUsageDigitalSignature,
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, ca, csr.PublicKey, caPriv.(crypto.Signer))
	if err != nil {
		return nil, err
	}
	pub, err := jwk.PublicJwk(csr.PublicKey)
	if err != nil {
		return nil, err
	}
	j := *pub
	j["use"] = "sig"
	j["x5c"] = []string{base64.StdEncoding.EncodeToString(der), base64.StdEncoding.EncodeToString(ca.Raw)}
	return &certificate{ID: uuid(), Type: certType, Status: "Active", JWK: j, Created: time.Now().UTC(),
		PEM: string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))}, nil
}

func (f *federation) api(prefix string) http.Handler {
	mux := http.NewServeMux()
	p := func(s string) string { // "GET /x" -> "GET <prefix>/x"
		method, path, _ := strings.Cut(s, " ")
		return method + " " + prefix + path
	}
	orgOK := func(w http.ResponseWriter, r *http.Request) bool {
		if r.PathValue("org") != f.org {
			fail(w, 404, "no such organisation")
			return false
		}
		return true
	}
	find := func(w http.ResponseWriter, r *http.Request) (string, *statement) {
		if !orgOK(w, r) {
			return "", nil
		}
		ssid := r.PathValue("ss")
		s := f.st.Statements[ssid]
		if s == nil {
			fail(w, 404, "no such software statement")
		}
		return ssid, s
	}

	mux.HandleFunc(p("GET /organisations/{org}/softwarestatements"), func(w http.ResponseWriter, r *http.Request) {
		if !orgOK(w, r) {
			return
		}
		f.mu.RLock()
		defer f.mu.RUnlock()
		out := []map[string]any{}
		for ssid, s := range f.st.Statements {
			out = append(out, f.statementView(ssid, s))
		}
		writeJSON(w, 200, out)
	})

	readBody := func(w http.ResponseWriter, r *http.Request) (map[string]any, json.RawMessage, bool) {
		var body map[string]any
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body); err != nil {
			fail(w, 400, "the body is not a JSON object")
			return nil, nil, false
		}
		var extra json.RawMessage
		if v, ok := body["FederationMetadataPolicy"]; ok {
			extra, _ = json.Marshal(v)
			delete(body, "FederationMetadataPolicy")
		}
		if asm, ok := body["AdditionalSoftwareMetadata"]; ok && asm != nil {
			if _, isString := asm.(string); !isString {
				b, _ := json.Marshal(asm)
				body["AdditionalSoftwareMetadata"] = string(b)
			}
		}
		return body, extra, true
	}

	mux.HandleFunc(p("POST /organisations/{org}/softwarestatements"), func(w http.ResponseWriter, r *http.Request) {
		if !orgOK(w, r) {
			return
		}
		body, extra, ok := readBody(w, r)
		if !ok {
			return
		}
		ssid := uuid()
		managed := str(body, "OpenidFederationEntityManagementType") == federationManaged
		var view map[string]any
		err := f.mutate(func() error {
			s := &statement{Record: body, ExtraPolicy: extra}
			if managed {
				k, err := newKey()
				if err != nil {
					return err
				}
				s.EntityKey = k
				body["ClientId"] = f.managedID(ssid)
			} else {
				id := strings.TrimSuffix(str(body, "ClientId"), "/")
				if _, err := model.ValidateEntityIdentifier(id); err != nil {
					return fmt.Errorf("ClientId: %w", err)
				}
				body["ClientId"] = id
			}
			body["SoftwareStatementId"], body["OrganisationId"] = ssid, f.org
			if str(body, "Status") == "" {
				body["Status"] = "Active"
			}
			body["CreatedOn"] = time.Now().UTC().Format(time.RFC3339)
			f.st.Statements[ssid] = s
			view = f.statementView(ssid, s)
			return nil
		})
		if err != nil {
			fail(w, 400, err.Error())
			return
		}
		f.logger.Info("software statement created", "id", ssid, "client_id", view["ClientId"], "managed", managed)
		writeJSON(w, 201, view)
	})

	mux.HandleFunc(p("GET /organisations/{org}/softwarestatements/{ss}"), func(w http.ResponseWriter, r *http.Request) {
		f.mu.RLock()
		defer f.mu.RUnlock()
		if ssid, s := find(w, r); s != nil {
			writeJSON(w, 200, f.statementView(ssid, s))
		}
	})

	mux.HandleFunc(p("PUT /organisations/{org}/softwarestatements/{ss}"), func(w http.ResponseWriter, r *http.Request) {
		body, extra, ok := readBody(w, r)
		if !ok {
			return
		}
		var view map[string]any
		err := f.mutate(func() error {
			ssid, s := find(w, r)
			if s == nil {
				return errors.New("")
			}
			for _, k := range []string{"SoftwareStatementId", "OrganisationId", "ClientId", "CreatedOn", "OpenidFederationEntityManagementType"} {
				body[k] = s.Record[k]
			}
			if st := str(body, "Status"); st != "Active" && st != "Suspended" && st != "Inactive" {
				body["Status"] = s.Record["Status"]
			}
			s.Record = body
			if extra != nil {
				s.ExtraPolicy = extra
			}
			view = f.statementView(ssid, s)
			return nil
		})
		if err != nil {
			if err.Error() != "" {
				fail(w, 400, err.Error())
			}
			return
		}
		f.logger.Info("software statement updated", "id", view["SoftwareStatementId"], "status", view["Status"])
		writeJSON(w, 200, view)
	})

	mux.HandleFunc(p("GET /organisations/{org}/softwarestatements/{ss}/certificates"), func(w http.ResponseWriter, r *http.Request) {
		f.mu.RLock()
		defer f.mu.RUnlock()
		if _, s := find(w, r); s != nil {
			out := []map[string]any{}
			for _, c := range s.Certificates {
				out = append(out, f.certView(c))
			}
			writeJSON(w, 200, out)
		}
	})

	mux.HandleFunc(p("POST /organisations/{org}/softwarestatements/{ss}/certificates/{type}"), func(w http.ResponseWriter, r *http.Request) {
		csr, _ := io.ReadAll(io.LimitReader(r.Body, 64<<10))
		var view map[string]any
		err := f.mutate(func() error {
			_, s := find(w, r)
			if s == nil {
				return errors.New("")
			}
			c, err := f.issue(csr, r.PathValue("type"))
			if err != nil {
				return err
			}
			for _, have := range activeCerts(s) { // the same key again: the certificate it already has
				if have.JWK["kid"] == c.JWK["kid"] {
					view = f.certView(have)
					return nil
				}
			}
			s.Certificates = append(s.Certificates, c)
			view = f.certView(c)
			return nil
		})
		if err != nil {
			if err.Error() != "" {
				fail(w, 400, err.Error())
			}
			return
		}
		f.logger.Info("certificate issued", "statement", r.PathValue("ss"), "type", r.PathValue("type"), "kid", view["kid"])
		writeJSON(w, 201, view)
	})

	// An organisation-level certificate (server_signing, say): the authorisation server's signing key, certified.
	mux.HandleFunc(p("POST /organisations/{org}/certificates/{type}"), func(w http.ResponseWriter, r *http.Request) {
		if !orgOK(w, r) {
			return
		}
		csr, _ := io.ReadAll(io.LimitReader(r.Body, 64<<10))
		f.mu.RLock()
		c, err := f.issue(csr, r.PathValue("type"))
		f.mu.RUnlock()
		if err != nil {
			fail(w, 400, err.Error())
			return
		}
		f.logger.Info("organisation certificate issued", "type", r.PathValue("type"), "kid", c.JWK["kid"])
		writeJSON(w, 201, f.certView(c))
	})

	mux.HandleFunc(p("GET /organisations/{org}/authorityclaims"), func(w http.ResponseWriter, r *http.Request) {
		if orgOK(w, r) {
			writeJSON(w, 200, f.orgClaims())
		}
	})

	mux.HandleFunc(p("GET /organisations/{org}/softwarestatements/{ss}/authorityclaims"), func(w http.ResponseWriter, r *http.Request) {
		f.mu.RLock()
		defer f.mu.RUnlock()
		if _, s := find(w, r); s != nil {
			writeJSON(w, 200, append([]*claim{}, s.Claims...))
		}
	})

	mux.HandleFunc(p("POST /organisations/{org}/softwarestatements/{ss}/authorityclaims"), func(w http.ResponseWriter, r *http.Request) {
		var in claim
		if err := json.NewDecoder(io.LimitReader(r.Body, 64<<10)).Decode(&in); err != nil || in.Role == "" {
			fail(w, 400, "body: {Role, AuthorisationDomain, OrganisationAuthorisationDomainRoleClaimID, Status}")
			return
		}
		if _, known := roleCapabilities[in.Role]; !known {
			fail(w, 400, "the organisation holds no claim for role "+in.Role)
			return
		}
		var made *claim
		err := f.mutate(func() error {
			_, s := find(w, r)
			if s == nil {
				return errors.New("")
			}
			for _, c := range s.Claims {
				if c.Role == in.Role {
					c.Status = "Active"
					made = c
					return nil
				}
			}
			made = &claim{ID: uuid(), OrgClaimID: orgClaimID(in.Role), Role: in.Role, Status: "Active", AuthorisationDomain: "CBA-Global"}
			s.Claims = append(s.Claims, made)
			return nil
		})
		if err != nil {
			if err.Error() != "" {
				fail(w, 400, err.Error())
			}
			return
		}
		writeJSON(w, 201, made)
	})

	// Not Raidiam's: what the authority would say, and an independent check of a chain with the library's client.
	mux.HandleFunc(p("GET /_state"), func(w http.ResponseWriter, r *http.Request) {
		f.mu.RLock()
		defer f.mu.RUnlock()
		ss := map[string]any{}
		for ssid, s := range f.st.Statements {
			ss[ssid] = map[string]any{"client_id": s.Record["ClientId"], "status": s.Record["Status"],
				"certificates": len(activeCerts(s)), "roles": s.Claims, "metadata_policy": f.policy(ssid, s)}
		}
		as := map[string]any{}
		for id, a := range f.st.AuthServers {
			as[id] = map[string]any{"issuer": a.Record["Issuer"], "keys_from_ec": len(a.JWKs) > 0, "fetched": a.Fetched, "error": a.Error}
		}
		writeJSON(w, 200, map[string]any{"trust_anchor": f.anchorID, "trust_anchor_jwks": f.anchor, "authority": f.authID,
			"organisation": f.org, "statements": ss, "authorisation_servers": as})
	})
	mux.HandleFunc(p("GET /_verify"), func(w http.ResponseWriter, r *http.Request) {
		sub := r.URL.Query().Get("sub")
		f.mu.RLock()
		cfg := model.ClientConfiguration{Configuration: f.common()}
		cfg.TrustAnchors = map[model.EntityIdentifier]josemodel.Jwks{f.anchorID: f.anchor}
		anchorID := f.anchorID
		f.mu.RUnlock()
		c := client.New(cfg)
		chain, statements, _, err := c.BuildTrustChain(r.Context(), sub, string(anchorID))
		if err != nil {
			fail(w, 422, "trust chain: "+err.Error())
			return
		}
		md, err := c.ResolveMetadata(r.Context(), sub, string(anchorID), chain)
		if err != nil {
			fail(w, 422, "resolve: "+err.Error())
			return
		}
		var path []string
		for _, s := range statements {
			path = append(path, fmt.Sprintf("%s -> %s", s.Iss, s.Sub))
		}
		writeJSON(w, 200, map[string]any{"chain": path, "metadata": md})
	})
	return mux
}

func (f *federation) public() http.Handler {
	mux := http.NewServeMux()
	participants := func(w http.ResponseWriter, r *http.Request) {
		f.mu.RLock()
		defer f.mu.RUnlock()
		var servers []map[string]any
		for _, as := range f.st.AuthServers {
			servers = append(servers, as.Record)
		}
		var claims []map[string]any
		for _, c := range f.orgClaims() {
			claims = append(claims, map[string]any{"AuthorisationDomain": c["AuthorisationDomain"], "Role": c["Role"],
				"Status": "Active", "RoleType": "Federation", "AuthorisationDomainRoleIdentifier": c["OrganisationAuthorityClaimId"], "Metadata": []any{}})
		}
		writeJSON(w, 200, []map[string]any{{
			"OrganisationId": f.org, "Status": "Active", "OrganisationName": f.orgName, "LegalEntityName": envOr("FED_ORG_LEGAL_NAME", "CBA"),
			"CountryOfRegistration": "AU", "City": "Sydney", "RegistrationNumber": "CBA", "AuthorisationServers": servers,
			"OrgDomainRoleClaims": claims, "OrgDomainClaims": []any{},
		}})
	}
	mux.HandleFunc("GET /directory", participants)
	mux.HandleFunc("GET /directory/participants", participants)
	mux.HandleFunc("GET /keystore/{org}/{ss}/application.jwks", func(w http.ResponseWriter, r *http.Request) {
		f.mu.RLock()
		defer f.mu.RUnlock()
		s := f.st.Statements[r.PathValue("ss")]
		if r.PathValue("org") != f.org || s == nil {
			http.NotFound(w, r)
			return
		}
		keys := []map[string]any{}
		for _, c := range activeCerts(s) {
			keys = append(keys, c.JWK)
		}
		writeJSON(w, 200, map[string]any{"keys": keys})
	})
	mux.Handle("/api/", f.api("/api"))
	mux.Handle("/", f) // the federation entities
	return mux
}

// ── main ────────────────────────────────────────────────────────────────────────────────────────

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	roots, _ := x509.SystemCertPool()
	if roots == nil {
		roots = x509.NewCertPool()
	}
	for _, p := range strings.Split(os.Getenv("FED_EXTRA_CA_FILES"), ",") {
		if p = strings.TrimSpace(p); p != "" {
			if b, err := os.ReadFile(p); err != nil || !roots.AppendCertsFromPEM(b) {
				logger.Warn("extra CA file not loaded", "path", p, "error", err)
			}
		}
	}
	f := &federation{
		base:       strings.TrimSuffix(envOr("FED_BASE_URL", "https://host.docker.internal:9443"), "/"),
		org:        envOr("FED_ORG_ID", "CBA-123"),
		orgName:    envOr("FED_ORG_NAME", "CBA-Payments"),
		dataDir:    envOr("FED_DATA", "/data"),
		httpClient: &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots}}},
		logger:     logger,
	}
	if err := f.load(); err != nil {
		log.Fatalf("state: %v", err)
	}
	if err := f.build(); err != nil {
		log.Fatalf("build: %v", err)
	}
	logger.Info("federation up", "trust_anchor", f.anchorID, "authority", f.authID, "statements", len(f.st.Statements),
		"authorisation_servers", len(f.st.AuthServers))
	go f.refreshAuthServers(context.Background())

	go func() {
		addr := envOr("FED_ADMIN_LISTEN", ":9444")
		logger.Info("admin API, plain HTTP (localhost only)", "listen", addr+"/api")
		log.Fatal(http.ListenAndServe(addr, f.public()))
	}()
	cert, key := envOr("FED_TLS_CERT", "/tls/tls.crt"), envOr("FED_TLS_KEY", "/tls/tls.key")
	srv := &http.Server{Addr: envOr("FED_LISTEN", ":9443"), Handler: f.public(), ReadHeaderTimeout: 10 * time.Second}
	logger.Info("federation, directory and API (HTTPS)", "listen", srv.Addr, "base", f.base)
	log.Fatal(srv.ListenAndServeTLS(cert, key))
}
