package netease

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

type qrPending struct {
	UniKey string `json:"unikey"`
	URL    string `json:"url"`
}

func (c *Client) LoginStart() (LoginStart, error) {
	data := map[string]interface{}{"type": 1, "noCheckToken": true}
	body, err := c.postWeapiQR(musicBaseURL+"/weapi/login/qrcode/unikey", data, false)
	if err != nil {
		return LoginStart{}, err
	}
	var result struct {
		Code   float64 `json:"code"`
		UniKey string  `json:"unikey"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return LoginStart{}, err
	}
	if result.Code != 200 || result.UniKey == "" {
		return LoginStart{}, fmt.Errorf("netease returned qr code %.0f", result.Code)
	}
	deviceID := c.ensureDeviceID()
	chainID := fmt.Sprintf("v1_%s_web_login_%d", deviceID, time.Now().UnixMilli())
	loginURL := "http://music.163.com/login?codekey=" + result.UniKey + "&chainId=" + chainID
	qrPath := c.path("qr.png")
	if err := qrcode.WriteFile(loginURL, qrcode.Medium, 320, qrPath); err != nil {
		return LoginStart{}, err
	}
	pendingRaw, _ := json.Marshal(qrPending{UniKey: result.UniKey, URL: loginURL})
	if err := writeAtomic(c.path("login.json"), pendingRaw, 0o600); err != nil {
		return LoginStart{}, err
	}
	if err := c.saveCookies(); err != nil {
		return LoginStart{}, err
	}
	return LoginStart{QRCodePath: qrPath, URL: loginURL}, nil
}

func (c *Client) LoginPoll() (LoginPoll, error) {
	raw, err := os.ReadFile(c.path("login.json"))
	if err != nil {
		return LoginPoll{}, fmt.Errorf("no active qr login")
	}
	var pending qrPending
	if err := json.Unmarshal(raw, &pending); err != nil || pending.UniKey == "" {
		return LoginPoll{}, fmt.Errorf("qr login state is invalid")
	}
	data := map[string]interface{}{"type": 1, "noCheckToken": true, "key": pending.UniKey}
	body, err := c.postWeapiQR(musicBaseURL+"/weapi/login/qrcode/client/login", data, true)
	if err != nil {
		return LoginPoll{}, err
	}
	var result struct {
		Code    float64 `json:"code"`
		Message string  `json:"message"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return LoginPoll{}, err
	}
	switch int(result.Code) {
	case 800:
		_ = os.Remove(c.path("login.json"))
		return LoginPoll{State: "expired", Message: "expired"}, nil
	case 801:
		return LoginPoll{State: "waiting", Message: "waiting"}, nil
	case 802:
		return LoginPoll{State: "scanned", Message: "scanned"}, nil
	case 803:
		if err := c.saveCookies(); err != nil {
			return LoginPoll{}, err
		}
		account, err := c.fetchAccount()
		if err != nil {
			return LoginPoll{State: "success", Message: "success", Account: Account{LoggedIn: true}}, nil
		}
		_ = saveAccount(c.accountCachePath(), account)
		_ = os.Remove(c.path("login.json"))
		_ = os.Remove(c.path("qr.png"))
		return LoginPoll{State: "success", Message: "success", Account: account}, nil
	default:
		message := result.Message
		if message == "" {
			message = fmt.Sprintf("login status %.0f", result.Code)
		}
		return LoginPoll{State: "error", Message: message}, nil
	}
}

func saveAccount(path string, account Account) error {
	raw, err := json.MarshalIndent(account, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(path, raw, 0o600)
}

func loadAccount(path string) (Account, bool) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return Account{}, false
	}
	var account Account
	if json.Unmarshal(raw, &account) != nil {
		return Account{}, false
	}
	return account, account.LoggedIn
}

func (c *Client) accountCachePath() string { return filepath.Join(c.dataDir, "account.json") }
