package netease

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/imroc/req/v3"
)

const (
	musicBaseURL = "https://music.163.com"
	webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)

type Client struct {
	dataDir string
	jar     http.CookieJar
	http    *http.Client
}

type savedCookie struct {
	Name     string    `json:"name"`
	Value    string    `json:"value"`
	Domain   string    `json:"domain,omitempty"`
	Path     string    `json:"path,omitempty"`
	Expires  time.Time `json:"expires,omitempty"`
	Secure   bool      `json:"secure,omitempty"`
	HTTPOnly bool      `json:"http_only,omitempty"`
}

func newHTTPClient(jar http.CookieJar, timeout time.Duration) *http.Client {
	dialer := &net.Dialer{Timeout: 4 * time.Second, KeepAlive: 30 * time.Second}
	transport := &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			return dialer.DialContext(ctx, "tcp4", address)
		},
		ForceAttemptHTTP2:     false,
		MaxIdleConns:          8,
		MaxIdleConnsPerHost:   4,
		IdleConnTimeout:       30 * time.Second,
		TLSHandshakeTimeout:   5 * time.Second,
		ResponseHeaderTimeout: 6 * time.Second,
	}
	return &http.Client{Jar: jar, Timeout: timeout, Transport: transport}
}

func New(dataDir string) (*Client, error) {
	if strings.TrimSpace(dataDir) == "" {
		return nil, errors.New("data directory is required")
	}
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, err
	}
	jar, err := cookiejar.New(nil)
	if err != nil {
		return nil, err
	}
	c := &Client{dataDir: dataDir, jar: jar}
	c.http = newHTTPClient(jar, 10*time.Second)
	c.loadCookies()
	return c, nil
}

func (c *Client) path(name string) string { return filepath.Join(c.dataDir, name) }

func (c *Client) cookieURL() *url.URL {
	u, _ := url.Parse(musicBaseURL)
	return u
}

func (c *Client) cookieValue(name string) string {
	for _, item := range c.jar.Cookies(c.cookieURL()) {
		if item.Name == name {
			return item.Value
		}
	}
	return ""
}

func (c *Client) ensureDeviceID() string {
	if value := c.cookieValue("sDeviceId"); value != "" {
		return value
	}
	const chars = "0123456789ABCDEF"
	random := make([]byte, 52)
	_, _ = rand.Read(random)
	raw := make([]byte, len(random))
	for i, value := range random {
		raw[i] = chars[int(value)%len(chars)]
	}
	value := string(raw)
	c.jar.SetCookies(c.cookieURL(), []*http.Cookie{{Name: "sDeviceId", Value: value, Path: "/"}})
	return value
}

func (c *Client) loadCookies() {
	raw, err := os.ReadFile(c.path("cookies.json"))
	if err != nil {
		return
	}
	var records []savedCookie
	if json.Unmarshal(raw, &records) != nil {
		return
	}
	grouped := map[string][]*http.Cookie{}
	for _, item := range records {
		host := strings.TrimPrefix(item.Domain, ".")
		if host == "" {
			host = "music.163.com"
		}
		grouped[host] = append(grouped[host], &http.Cookie{
			Name: item.Name, Value: item.Value, Domain: item.Domain, Path: item.Path,
			Expires: item.Expires, Secure: item.Secure, HttpOnly: item.HTTPOnly,
		})
	}
	for host, cookies := range grouped {
		u, _ := url.Parse("https://" + host + "/")
		if u != nil {
			c.jar.SetCookies(u, cookies)
		}
	}
}

func (c *Client) saveCookies() error {
	seen := map[string]bool{}
	var records []savedCookie
	for _, rawURL := range []string{"https://music.163.com/", "https://music.163.com/weapi/", "https://music.163.com/api/"} {
		u, _ := url.Parse(rawURL)
		for _, item := range c.jar.Cookies(u) {
			key := item.Name + "\x00" + item.Domain + "\x00" + item.Path
			if seen[key] {
				continue
			}
			seen[key] = true
			records = append(records, savedCookie{
				Name: item.Name, Value: item.Value, Domain: item.Domain, Path: item.Path,
				Expires: item.Expires, Secure: item.Secure, HTTPOnly: item.HttpOnly,
			})
		}
	}
	raw, err := json.MarshalIndent(records, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(c.path("cookies.json"), raw, 0o600)
}

func (c *Client) postForm(rawURL string, form map[string]string, noJar bool, clientOverride ...*http.Client) ([]byte, error) {
	values := url.Values{}
	for k, v := range form {
		values.Set(k, v)
	}
	request, err := http.NewRequest(http.MethodPost, rawURL, strings.NewReader(values.Encode()))
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", webUserAgent)
	request.Header.Set("Referer", musicBaseURL+"/")
	request.Header.Set("Origin", musicBaseURL)
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
	client := c.http
	if len(clientOverride) > 0 && clientOverride[0] != nil {
		client = clientOverride[0]
	} else if noJar {
		client = &http.Client{Timeout: 45 * time.Second}
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	payload, err := io.ReadAll(io.LimitReader(response.Body, 32*1024*1024))
	if err != nil {
		return nil, err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return payload, fmt.Errorf("HTTP %d: %s", response.StatusCode, strings.TrimSpace(string(payload)))
	}
	return payload, nil
}

func (c *Client) postWeapi(apiURL string, data map[string]interface{}) ([]byte, error) {
	return c.postWeapiWithTimeout(apiURL, data, c.http.Timeout)
}

func (c *Client) postWeapiWithTimeout(apiURL string, data map[string]interface{}, timeout time.Duration) ([]byte, error) {
	if data == nil {
		data = map[string]interface{}{}
	}
	data["csrf_token"] = c.cookieValue("__csrf")
	params, err := encodeWeapi(data)
	if err != nil {
		return nil, err
	}
	client := newHTTPClient(c.jar, timeout)
	return c.postForm(apiURL, params, false, client)
}

func (c *Client) postLinuxAPI(apiURL string, data map[string]interface{}) ([]byte, error) {
	params, err := encodeLinuxAPI(apiURL, http.MethodPost, data)
	if err != nil {
		return nil, err
	}
	return c.postForm(musicBaseURL+"/api/linux/forward", params, false)
}

func (c *Client) postWeapiQR(apiURL string, data map[string]interface{}, useJar bool) ([]byte, error) {
	if data == nil {
		data = map[string]interface{}{}
	}
	if useJar {
		data["csrf_token"] = c.cookieValue("__csrf")
	}
	params, err := encodeWeapi(data)
	if err != nil {
		return nil, err
	}
	headers := map[string]string{
		"Referer":         musicBaseURL + "/",
		"Origin":          musicBaseURL,
		"Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
		"Cache-Control":   "no-cache",
		"Pragma":          "no-cache",
	}
	return c.qrRequest(apiURL, params, useJar, headers)
}

func (c *Client) qrRequest(rawURL string, form map[string]string, useJar bool, headers map[string]string) ([]byte, error) {
	client := req.C().SetUserAgent(webUserAgent).SetTLSFingerprintChrome()
	if useJar {
		client.SetCookieJar(c.jar)
	} else {
		client.SetCookieJar(nil)
	}
	request := client.R().SetFormData(form)
	if len(headers) > 0 {
		request.SetHeaders(headers)
	}
	response, err := request.Post(rawURL)
	if err != nil {
		return nil, err
	}
	return response.Bytes(), nil
}

func decodeCode(body []byte) float64 {
	var value struct {
		Code float64 `json:"code"`
	}
	if json.Unmarshal(body, &value) == nil {
		return value.Code
	}
	return 0
}

func trimField(value string) string {
	value = strings.ReplaceAll(value, "\t", " ")
	value = strings.ReplaceAll(value, "\r", " ")
	value = strings.ReplaceAll(value, "\n", " ")
	return strings.TrimSpace(value)
}

func writeAtomic(path string, data []byte, mode os.FileMode) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
