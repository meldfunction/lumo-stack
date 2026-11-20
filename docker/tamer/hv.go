// Human verification (CAPTCHA) for lumo-tamer's direct Proton login.
// Added at build time by Lumo Stack; upstream fails the login instead.
//
// When Proton answers a login with "human verification required" (code 9001),
// print the verification link, wait for a line on stdin (the person solved the
// CAPTCHA in their own browser), then retry the login once with the verified
// token in Proton's human-verification headers. Same approach as Proton Bridge.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"

	"github.com/henrybear327/go-proton-api"
)

var hvToken, hvType string

type hvTransport struct{ base http.RoundTripper }

func (t hvTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if hvToken != "" {
		r = r.Clone(r.Context())
		r.Header.Set("x-pm-human-verification-token", hvToken)
		r.Header.Set("x-pm-human-verification-token-type", hvType)
	}
	return t.base.RoundTrip(r)
}

func newHVTransport() http.RoundTripper { return hvTransport{base: http.DefaultTransport} }

func loginWithHV(ctx context.Context, m *proton.Manager, reader *bufio.Reader, username string, password []byte) (*proton.Client, proton.Auth, error) {
	client, auth, err := m.NewClientWithLogin(ctx, username, password)
	var apiErr *proton.APIError
	if err == nil || !errors.As(err, &apiErr) || apiErr.Code != proton.HumanVerificationRequired {
		return client, auth, err
	}
	raw, _ := json.Marshal(apiErr.Details)
	var hv struct {
		HumanVerificationToken   string
		HumanVerificationMethods []string
	}
	_ = json.Unmarshal(raw, &hv)
	if hv.HumanVerificationToken == "" {
		return client, auth, err
	}
	// Machine-readable line for Lumo Home, then a human prompt for terminals.
	fmt.Fprintf(os.Stderr, "LUMO_HV_URL https://verify.proton.me/?methods=captcha&token=%s\n", hv.HumanVerificationToken)
	fmt.Fprint(os.Stderr, "Proton wants a CAPTCHA. Open the link above, solve it, then press Enter: ")
	if _, e := reader.ReadString('\n'); e != nil {
		return client, auth, err
	}
	hvToken, hvType = hv.HumanVerificationToken, "captcha"
	return m.NewClientWithLogin(ctx, username, password)
}
