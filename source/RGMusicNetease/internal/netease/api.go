package netease

import (
	"encoding/json"
	"fmt"
	"net/http/cookiejar"
	"os"
	"strconv"
	"strings"
)

func (c *Client) Status() (Account, error) {
	if c.cookieValue("MUSIC_U") == "" {
		return Account{}, nil
	}
	account, err := c.fetchAccount()
	if err != nil {
		if cached, ok := loadAccount(c.accountCachePath()); ok {
			return cached, nil
		}
		return Account{}, err
	}
	_ = saveAccount(c.accountCachePath(), account)
	return account, nil
}

func (c *Client) fetchAccount() (Account, error) {
	body, err := c.postWeapi(musicBaseURL+"/weapi/nuser/account/get", map[string]interface{}{})
	if err != nil {
		return Account{}, err
	}
	var response struct {
		Code    float64 `json:"code"`
		Account struct {
			ID          int64 `json:"id"`
			VipType     int   `json:"vipType"`
			RedVipLevel int   `json:"redVipLevel"`
			VipLevel    int   `json:"vipLevel"`
		} `json:"account"`
		Profile struct {
			UserID      int64  `json:"userId"`
			Nickname    string `json:"nickname"`
			VipType     int    `json:"vipType"`
			RedVipLevel int    `json:"redVipLevel"`
			VipLevel    int    `json:"vipLevel"`
		} `json:"profile"`
	}
	if err := json.Unmarshal(body, &response); err != nil {
		return Account{}, err
	}
	uid := response.Profile.UserID
	if uid == 0 {
		uid = response.Account.ID
	}
	if response.Code != 200 || uid == 0 {
		return Account{}, fmt.Errorf("account is not logged in")
	}
	vipType, redVipLevel, vipLevel := response.Profile.VipType, response.Profile.RedVipLevel, response.Profile.VipLevel
	if response.Account.VipType > vipType {
		vipType = response.Account.VipType
	}
	if response.Account.RedVipLevel > redVipLevel {
		redVipLevel = response.Account.RedVipLevel
	}
	if response.Account.VipLevel > vipLevel {
		vipLevel = response.Account.VipLevel
	}
	return Account{LoggedIn: true, Nickname: response.Profile.Nickname, UID: uid, VipType: vipType, RedVipLevel: redVipLevel, VipLevel: vipLevel}, nil
}

func (c *Client) Playlists() ([]Playlist, error) {
	account, err := c.Status()
	if err != nil || !account.LoggedIn {
		return nil, fmt.Errorf("please login to netease first")
	}
	body, err := c.postWeapi(musicBaseURL+"/weapi/user/playlist", map[string]interface{}{
		"uid": strconv.FormatInt(account.UID, 10), "limit": "100", "offset": "0",
	})
	if err != nil {
		return nil, err
	}
	var response struct {
		Code     float64 `json:"code"`
		Playlist []struct {
			ID         int64  `json:"id"`
			Name       string `json:"name"`
			TrackCount int    `json:"trackCount"`
			CoverURL   string `json:"coverImgUrl"`
			Creator    struct {
				Nickname string `json:"nickname"`
			} `json:"creator"`
		} `json:"playlist"`
	}
	if err := json.Unmarshal(body, &response); err != nil {
		return nil, err
	}
	if response.Code != 200 {
		return nil, fmt.Errorf("netease playlist code %.0f", response.Code)
	}
	result := make([]Playlist, 0, len(response.Playlist))
	for _, item := range response.Playlist {
		result = append(result, Playlist{ID: item.ID, Name: item.Name, TrackCount: item.TrackCount, CoverURL: item.CoverURL, Creator: item.Creator.Nickname})
	}
	return result, nil
}

type rawArtist struct {
	Name string `json:"name"`
}
type rawAlbum struct {
	Name   string `json:"name"`
	PicURL string `json:"picUrl"`
}
type rawSong struct {
	ID         int64       `json:"id"`
	Name       string      `json:"name"`
	AR         []rawArtist `json:"ar"`
	Artists    []rawArtist `json:"artists"`
	AL         rawAlbum    `json:"al"`
	Album      rawAlbum    `json:"album"`
	DT         int64       `json:"dt"`
	DurationMS int64       `json:"duration"`
}

func parseTracks(songs []rawSong) []Track {
	result := make([]Track, 0, len(songs))
	for _, song := range songs {
		artists := song.AR
		if len(artists) == 0 {
			artists = song.Artists
		}
		names := make([]string, 0, len(artists))
		for _, artist := range artists {
			if strings.TrimSpace(artist.Name) != "" {
				names = append(names, artist.Name)
			}
		}
		album := song.AL
		if album.Name == "" {
			album = song.Album
		}
		duration := song.DT
		if duration == 0 {
			duration = song.DurationMS
		}
		result = append(result, Track{ID: song.ID, Title: song.Name, Artist: strings.Join(names, " / "), Album: album.Name, Duration: int(duration / 1000), CoverURL: album.PicURL, Available: true})
	}
	return result
}

func (c *Client) PlaylistTracks(id string) ([]Track, error) {
	if id == "daily" {
		body, err := c.postWeapi(musicBaseURL+"/weapi/v3/discovery/recommend/songs", map[string]interface{}{})
		if err != nil {
			return nil, err
		}
		var response struct {
			Data struct {
				DailySongs []rawSong `json:"dailySongs"`
			} `json:"data"`
			Recommend []rawSong `json:"recommend"`
		}
		if err := json.Unmarshal(body, &response); err != nil {
			return nil, err
		}
		songs := response.Data.DailySongs
		if len(songs) == 0 {
			songs = response.Recommend
		}
		return parseTracks(songs), nil
	}
	body, err := c.postLinuxAPI(musicBaseURL+"/api/v3/playlist/detail", map[string]interface{}{"id": id, "n": 1000, "s": 8})
	if err != nil {
		return nil, err
	}
	var response struct {
		Code     float64 `json:"code"`
		Playlist struct {
			Tracks   []rawSong `json:"tracks"`
			TrackIDs []struct {
				ID int64 `json:"id"`
			} `json:"trackIds"`
		} `json:"playlist"`
	}
	if err := json.Unmarshal(body, &response); err != nil {
		return nil, err
	}
	if len(response.Playlist.Tracks) > 0 {
		return parseTracks(response.Playlist.Tracks), nil
	}
	if len(response.Playlist.TrackIDs) == 0 {
		return nil, fmt.Errorf("playlist has no tracks")
	}
	ids := make([]string, 0, len(response.Playlist.TrackIDs))
	for _, item := range response.Playlist.TrackIDs {
		ids = append(ids, strconv.FormatInt(item.ID, 10))
	}
	return c.SongDetails(ids)
}

func (c *Client) SongDetails(ids []string) ([]Track, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	var result []Track
	for start := 0; start < len(ids); start += 200 {
		end := start + 200
		if end > len(ids) {
			end = len(ids)
		}
		chunk := ids[start:end]
		cItems := make([]map[string]string, 0, len(chunk))
		for _, id := range chunk {
			cItems = append(cItems, map[string]string{"id": id})
		}
		cList, _ := json.Marshal(cItems)
		body, err := c.postWeapi(musicBaseURL+"/weapi/v3/song/detail", map[string]interface{}{"c": string(cList), "ids": "[" + strings.Join(chunk, ",") + "]"})
		if err != nil {
			return nil, err
		}
		var response struct {
			Songs []rawSong `json:"songs"`
		}
		if err := json.Unmarshal(body, &response); err != nil {
			return nil, err
		}
		result = append(result, parseTracks(response.Songs)...)
	}
	return result, nil
}

func (c *Client) SearchTracks(query string, limit int) ([]Track, error) {
	if limit <= 0 || limit > 100 {
		limit = 30
	}
	body, err := c.postWeapi(musicBaseURL+"/weapi/cloudsearch/pc", map[string]interface{}{"type": "1", "s": query, "limit": strconv.Itoa(limit), "offset": "0"})
	if err != nil {
		return nil, err
	}
	var response struct {
		Result struct {
			Songs []rawSong `json:"songs"`
		} `json:"result"`
	}
	if err := json.Unmarshal(body, &response); err != nil {
		return nil, err
	}
	return parseTracks(response.Result.Songs), nil
}

func (c *Client) Logout() error {
	jar, _ := cookiejar.New(nil)
	c.jar = jar
	c.http.Jar = jar
	for _, name := range []string{"cookies.json", "account.json", "login.json", "qr.png"} {
		_ = os.Remove(c.path(name))
	}
	return nil
}
