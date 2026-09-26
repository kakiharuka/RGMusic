package netease

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
)

const (
	presetKeyHex = "0CoJUm6Qyw8W8jud"
	linuxKeyHex  = "rFgB&h#%2?^eDg:Q"
)

var (
	cryptoIV      = []byte("0102030405060708")
	cryptoRunes   = []byte("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
	neteasePubPEM = []byte("-----BEGIN PUBLIC KEY-----\nMIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB\n-----END PUBLIC KEY-----")
)

func pkcs7Pad(data []byte, blockSize int) []byte {
	padding := blockSize - len(data)%blockSize
	return append(data, bytes.Repeat([]byte{byte(padding)}, padding)...)
}

func aesCBC(data, key, iv []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	padded := pkcs7Pad(data, block.BlockSize())
	out := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(out, padded)
	return out, nil
}

func aesECB(data, key []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	padded := pkcs7Pad(data, block.BlockSize())
	out := make([]byte, len(padded))
	for start := 0; start < len(padded); start += block.BlockSize() {
		block.Encrypt(out[start:start+block.BlockSize()], padded[start:start+block.BlockSize()])
	}
	return out, nil
}

func randomSecret() ([]byte, []byte, error) {
	first := make([]byte, 16)
	second := make([]byte, 16)
	for i := range first {
		value, err := rand.Int(rand.Reader, big.NewInt(int64(len(cryptoRunes))))
		if err != nil {
			return nil, nil, err
		}
		first[i] = cryptoRunes[value.Int64()]
	}
	for i := range first {
		second[15-i] = first[i]
	}
	return first, second, nil
}

func rsaNoPadding(data, pemKey []byte) ([]byte, error) {
	block, _ := pem.Decode(pemKey)
	if block == nil {
		return nil, errors.New("invalid RSA public key")
	}
	pubAny, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	pub, ok := pubAny.(*rsa.PublicKey)
	if !ok {
		return nil, errors.New("unexpected RSA public key type")
	}
	buf := make([]byte, pub.Size()*0)
	buf = append(buf, make([]byte, pub.Size()-len(data))...)
	buf = append(buf, data...)
	c := new(big.Int).SetBytes(buf)
	c.Exp(c, big.NewInt(int64(pub.E)), pub.N)
	out := c.Bytes()
	padded := make([]byte, pub.Size())
	copy(padded[len(padded)-len(out):], out)
	return padded, nil
}

func encodeWeapi(data map[string]interface{}) (map[string]string, error) {
	raw, err := json.Marshal(data)
	if err != nil {
		return nil, err
	}
	first, second, err := randomSecret()
	if err != nil {
		return nil, err
	}
	stage1, err := aesCBC(raw, []byte(presetKeyHex), cryptoIV)
	if err != nil {
		return nil, err
	}
	stage1Base64 := base64.StdEncoding.EncodeToString(stage1)
	stage2, err := aesCBC([]byte(stage1Base64), second, cryptoIV)
	if err != nil {
		return nil, err
	}
	encryptedKey, err := rsaNoPadding(first, neteasePubPEM)
	if err != nil {
		return nil, err
	}
	return map[string]string{
		"params":    base64.StdEncoding.EncodeToString(stage2),
		"encSecKey": hex.EncodeToString(encryptedKey),
	}, nil
}

func encodeLinuxAPI(apiURL, method string, params map[string]interface{}) (map[string]string, error) {
	payload := map[string]interface{}{
		"method": method,
		"url":    apiURL,
		"params": params,
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	encrypted, err := aesECB(raw, []byte(linuxKeyHex))
	if err != nil {
		return nil, err
	}
	return map[string]string{"eparams": fmt.Sprintf("%X", encrypted)}, nil
}
