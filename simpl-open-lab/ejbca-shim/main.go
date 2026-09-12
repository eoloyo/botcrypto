// Lightweight EJBCA-compatible CA shim for Simpl-Open IAA (identity-provider).
// Implements only the EJBCA REST surface that Simpl actually calls:
//   POST /ejbca/ejbca-rest-api/v1/certificate/pkcs10enroll
//   GET  /ejbca/ejbca-rest-api/v1/ca/{subject_dn}/certificate/download
//   PUT  /ejbca/ejbca-rest-api/v1/certificate/{issuer}/{serial}/revoke
//   GET  /ejbca/ejbca-rest-api/v1/certificate/{issuer}/{serial}/revocationstatus
// Backed by a locally generated Root CA. stdlib only.
package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"log"
	"math/big"
	"net/http"
	"strings"
	"time"
)

var (
	caCert *x509.Certificate
	caKey  *rsa.PrivateKey
	caDER  []byte
)

type enrollReq struct {
	CertificateRequest       string `json:"certificate_request"`
	CertificateProfileName   string `json:"certificate_profile_name"`
	EndEntityProfileName     string `json:"end_entity_profile_name"`
	CertificateAuthorityName string `json:"certificate_authority_name"`
	Username                 string `json:"username"`
	Password                 string `json:"password"`
	IncludeChain             bool   `json:"include_chain"`
}

type enrollResp struct {
	Certificate      string   `json:"certificate"`
	SerialNumber     string   `json:"serial_number"`
	ResponseFormat   string   `json:"response_format"`
	CertificateChain []string `json:"certificate_chain"`
}

type revokeResp struct {
	IssuerDN     string `json:"issuer_dn"`
	SerialNumber string `json:"serial_number"`
	RevocationReason string `json:"revocation_reason"`
	Revoked      bool   `json:"revoked"`
	Status       string `json:"status"`
}

func initCA() {
	caKey, _ = rsa.GenerateKey(rand.Reader, 2048)
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "OnBoardingCA", Organization: []string{"Simpl-Open (local)"}},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().AddDate(10, 0, 0),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign | x509.KeyUsageDigitalSignature,
	}
	caDER, _ = x509.CreateCertificate(rand.Reader, tmpl, tmpl, &caKey.PublicKey, caKey)
	caCert, _ = x509.ParseCertificate(caDER)
	log.Printf("Root CA ready: CN=%s", caCert.Subject.CommonName)
}

func b64(der []byte) string { return base64.StdEncoding.EncodeToString(der) }

func enroll(w http.ResponseWriter, r *http.Request) {
	var req enrollReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	block, _ := pem.Decode([]byte(req.CertificateRequest))
	if block == nil {
		http.Error(w, `[{"error_message":"invalid PEM CSR"}]`, 400)
		return
	}
	csr, err := x509.ParseCertificateRequest(block.Bytes)
	if err != nil || csr.CheckSignature() != nil {
		http.Error(w, `[{"error_message":"invalid CSR / bad signature"}]`, 400)
		return
	}
	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	leaf := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               csr.Subject,
		NotBefore:             time.Now().Add(-time.Minute),
		NotAfter:              time.Now().AddDate(1, 0, 0),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
		DNSNames:              csr.DNSNames,
		BasicConstraintsValid: true,
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leaf, caCert, csr.PublicKey, caKey)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	log.Printf("Issued cert: subject=%q serial=%x (CA=%s, profile=%s)", csr.Subject.String(), serial, req.CertificateAuthorityName, req.CertificateProfileName)
	resp := enrollResp{
		Certificate:    b64(leafDER),
		SerialNumber:   fmt.Sprintf("%X", serial),
		ResponseFormat: "DER",
	}
	if req.IncludeChain {
		resp.CertificateChain = []string{b64(caDER)}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func caDownload(w http.ResponseWriter, r *http.Request) {
	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER})
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Write(pemBytes)
}

func revoke(w http.ResponseWriter, r *http.Request) {
	json.NewEncoder(w).Encode(revokeResp{Revoked: true, Status: "REVOKED"})
}
func revStatus(w http.ResponseWriter, r *http.Request) {
	json.NewEncoder(w).Encode(revokeResp{Revoked: false, Status: "NOT_REVOKED"})
}

func router(w http.ResponseWriter, r *http.Request) {
	p := r.URL.Path
	switch {
	case r.Method == "POST" && strings.HasSuffix(p, "/certificate/pkcs10enroll"):
		enroll(w, r)
	case r.Method == "GET" && strings.HasSuffix(p, "/certificate/download"):
		caDownload(w, r)
	case r.Method == "PUT" && strings.HasSuffix(p, "/revoke"):
		revoke(w, r)
	case r.Method == "GET" && strings.HasSuffix(p, "/revocationstatus"):
		revStatus(w, r)
	case p == "/status" || p == "/":
		w.Write([]byte(`{"status":"UP","ca":"OnBoardingCA"}`))
	default:
		log.Printf("unhandled %s %s", r.Method, p)
		http.NotFound(w, r)
	}
}

func main() {
	initCA()
	// generate a self-signed server cert for HTTPS on :30443 (what identity-provider expects)
	srvKey, _ := rsa.GenerateKey(rand.Reader, 2048)
	srvTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: "localhost"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().AddDate(1, 0, 0),
		DNSNames:     []string{"localhost"},
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	srvDER, _ := x509.CreateCertificate(rand.Reader, srvTmpl, srvTmpl, &srvKey.PublicKey, srvKey)
	tlsCert := tls.Certificate{Certificate: [][]byte{srvDER}, PrivateKey: srvKey}

	mux := http.HandlerFunc(router)
	// HTTP on 30080 (easy direct testing) + HTTPS on 30443 (identity-provider default)
	go func() {
		log.Println("EJBCA-shim HTTP  on :30080")
		log.Fatal(http.ListenAndServe("127.0.0.1:30080", mux))
	}()
	srv := &http.Server{
		Addr:      "127.0.0.1:30443",
		Handler:   mux,
		TLSConfig: &tls.Config{Certificates: []tls.Certificate{tlsCert}},
	}
	log.Println("EJBCA-shim HTTPS on :30443")
	log.Fatal(srv.ListenAndServeTLS("", ""))
}
