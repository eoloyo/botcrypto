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
	"io"
	"log"
	"math/big"
	"net/http"
	"os"
	"strings"
	"time"

	"golang.org/x/crypto/ocsp"
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

const caCertPath = "/tmp/shim-ca.pem"
const caKeyPath = "/tmp/shim-ca.key"

func initCA() {
	// Reuse a persisted CA across restarts so issued certs, the OCSP responder,
	// and downstream truststores all chain to one stable authority.
	if cb, err := pemReadFile(caCertPath); err == nil {
		if kb, err2 := pemReadFile(caKeyPath); err2 == nil {
			caCert, _ = x509.ParseCertificate(cb)
			caKey, _ = x509.ParsePKCS1PrivateKey(kb)
			caDER = cb
			if caCert != nil && caKey != nil {
				log.Printf("Root CA loaded: CN=%s", caCert.Subject.CommonName)
				return
			}
		}
	}
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
	_ = writePEM(caCertPath, "CERTIFICATE", caDER)
	_ = writePEM(caKeyPath, "RSA PRIVATE KEY", x509.MarshalPKCS1PrivateKey(caKey))
	log.Printf("Root CA ready: CN=%s (persisted to %s)", caCert.Subject.CommonName, caCertPath)
}

func pemReadFile(path string) ([]byte, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	blk, _ := pem.Decode(b)
	if blk == nil {
		return nil, fmt.Errorf("no PEM in %s", path)
	}
	return blk.Bytes, nil
}

func writePEM(path, typ string, der []byte) error {
	return os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: typ, Bytes: der}), 0600)
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
		// Authority Information Access (AIA): the Simpl IAA credential validation
		// (eu.europa.ec.simpl.client.util) requires this extension to be present.
		OCSPServer:            []string{"http://localhost:30081/ocsp"},
		IssuingCertificateURL: []string{"http://localhost:30080/ejbca/publicweb/webdist/certdist?cmd=iep&issuer=OnBoardingCA"},
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

// ocspNonceOID is id-pkix-ocsp-nonce (1.3.6.1.5.5.7.48.1.2).
var ocspNonceOID = []int{1, 3, 6, 1, 5, 5, 7, 48, 1, 2}

// extractNonce pulls the OCSP nonce extension out of a raw request so the response
// can echo it (the Simpl client requires the response nonce to match the request).
func extractNonce(der []byte) *pkix.Extension {
	// DER of the nonce OID inside an Extension: 06 09 2B 06 01 05 05 07 30 01 02
	oid := []byte{0x06, 0x09, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x30, 0x01, 0x02}
	i := bytesIndex(der, oid)
	if i < 0 {
		return nil
	}
	j := i + len(oid)
	if j >= len(der) || der[j] != 0x04 { // extnValue OCTET STRING
		return nil
	}
	j++
	if j >= len(der) {
		return nil
	}
	ln := int(der[j])
	j++
	if der[j-1]&0x80 != 0 { // long form length
		nb := int(der[j-1] & 0x7f)
		ln = 0
		for k := 0; k < nb && j < len(der); k++ {
			ln = ln<<8 | int(der[j])
			j++
		}
	}
	if j+ln > len(der) {
		return nil
	}
	return &pkix.Extension{Id: ocspNonceOID, Value: der[j : j+ln]}
}

func bytesIndex(h, n []byte) int {
	for i := 0; i+len(n) <= len(h); i++ {
		if string(h[i:i+len(n)]) == string(n) {
			return i
		}
	}
	return -1
}

func ocspHandler(w http.ResponseWriter, r *http.Request) {
	der, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	req, err := ocsp.ParseRequest(der)
	if err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	tmpl := ocsp.Response{
		Status:       ocsp.Good,
		SerialNumber: req.SerialNumber,
		ThisUpdate:   time.Now().Add(-time.Minute),
		NextUpdate:   time.Now().AddDate(0, 0, 7),
		IssuerHash:   req.HashAlgorithm,
	}
	if nonce := extractNonce(der); nonce != nil {
		tmpl.ExtraExtensions = []pkix.Extension{*nonce}
	}
	resp, err := ocsp.CreateResponse(caCert, caCert, tmpl, caKey)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	w.Header().Set("Content-Type", "application/ocsp-response")
	w.Write(resp)
}

func router(w http.ResponseWriter, r *http.Request) {
	p := r.URL.Path
	switch {
	case r.Method == "POST" && strings.HasSuffix(p, "/certificate/pkcs10enroll"):
		enroll(w, r)
	case r.Method == "GET" && strings.HasSuffix(p, "/certificate/download"):
		caDownload(w, r)
	// AIA CA-Issuers endpoint: the Simpl IAA credential validation fetches the
	// issuer (CA) certificate from here (id-ad-caIssuers). Return DER (pkix-cert).
	case r.Method == "GET" && strings.HasSuffix(p, "/certdist"):
		w.Header().Set("Content-Type", "application/pkix-cert")
		w.Write(caDER)
	// OCSP responder: the Simpl IAA revocation check (OCSPIdentityVerifier /
	// CertificateRevocationTrustManager) POSTs an OCSP request here; every serial
	// this local CA issued is reported Good.
	case r.Method == "POST" && strings.HasSuffix(p, "/ocsp"):
		ocspHandler(w, r)
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
