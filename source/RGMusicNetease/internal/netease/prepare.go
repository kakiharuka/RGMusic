package netease

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

func (c *Client) cacheDir() string { return filepath.Join(c.dataDir, "cache") }

func (c *Client) writeProgress(phase, title string, current, total int64) {
	percent := 0
	if total > 0 {
		percent = int(current * 100 / total)
	}
	data := fmt.Sprintf("%s\t%d\t%d\t%d\t%s\n", trimField(phase), current, total, percent, trimField(title))
	_ = writeAtomic(filepath.Join(c.cacheDir(), "progress.tsv"), []byte(data), 0o600)
}

func downloadFile(rawURL, path, title string, progress func(current, total int64)) error {
	request, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return err
	}
	request.Header.Set("User-Agent", webUserAgent)
	request.Header.Set("Referer", musicBaseURL+"/")
	client := newHTTPClient(nil, 5*time.Minute)
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		payload, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		return fmt.Errorf("download HTTP %d: %s", response.StatusCode, strings.TrimSpace(string(payload)))
	}
	tmp := path + ".part"
	file, err := os.Create(tmp)
	if err != nil {
		return err
	}
	total := response.ContentLength
	var current int64
	buffer := make([]byte, 128*1024)
	lastUpdate := time.Now()
	for {
		count, readErr := response.Body.Read(buffer)
		if count > 0 {
			if _, err := file.Write(buffer[:count]); err != nil {
				file.Close()
				os.Remove(tmp)
				return err
			}
			current += int64(count)
			if progress != nil && time.Since(lastUpdate) >= 250*time.Millisecond {
				progress(current, total)
				lastUpdate = time.Now()
			}
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			file.Close()
			os.Remove(tmp)
			return readErr
		}
	}
	if err := file.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if progress != nil {
		progress(current, total)
	}
	return os.Rename(tmp, path)
}

func appendImageParam(rawURL string, size int) string {
	if rawURL == "" {
		return ""
	}
	separator := "?"
	if strings.Contains(rawURL, "?") {
		separator = "&"
	}
	return rawURL + separator + "param=" + strconv.Itoa(size) + "y" + strconv.Itoa(size)
}

var streamProbeClient = newHTTPClient(nil, 2*time.Second)

func streamURLCandidates(rawURL string) []string {
	parsed, err := url.Parse(rawURL)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		return []string{rawURL}
	}
	hosts := []string{parsed.Host, "m801.music.126.net", "m704.music.126.net"}
	seen := map[string]bool{}
	result := make([]string, 0, len(hosts))
	for _, host := range hosts {
		if seen[host] {
			continue
		}
		seen[host] = true
		candidate := *parsed
		candidate.Host = host
		result = append(result, candidate.String())
	}
	return result
}

func probeStreamURL(ctx context.Context, rawURL string) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return err
	}
	request.Header.Set("User-Agent", webUserAgent)
	request.Header.Set("Referer", musicBaseURL+"/")
	request.Header.Set("Range", "bytes=0-1")
	response, err := streamProbeClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	_, _ = io.CopyN(io.Discard, response.Body, 4096)
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusPartialContent {
		return fmt.Errorf("stream HTTP %d", response.StatusCode)
	}
	return nil
}

func choosePlayableURL(rawURL string) (string, error) {
	candidates := streamURLCandidates(rawURL)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	type probeResult struct {
		url string
		err error
	}
	results := make(chan probeResult, len(candidates))
	for _, candidate := range candidates {
		go func(item string) {
			probeCtx, probeCancel := context.WithTimeout(ctx, 2*time.Second)
			defer probeCancel()
			err := probeStreamURL(probeCtx, item)
			select {
			case results <- probeResult{url: item, err: err}:
			case <-ctx.Done():
			}
		}(candidate)
	}
	var lastErr error
	for range candidates {
		select {
		case result := <-results:
			if result.err == nil {
				cancel()
				return result.url, nil
			}
			lastErr = result.err
		case <-ctx.Done():
			return "", ctx.Err()
		}
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("no stream URL candidate was reachable")
	}
	return "", lastErr
}

func (c *Client) Prepare(id, quality string) (PreparedTrack, error) {
	if quality == "" {
		quality = "exhigh"
	}
	tracks, err := c.SongDetails([]string{id})
	if err != nil {
		return PreparedTrack{}, err
	}
	if len(tracks) == 0 {
		return PreparedTrack{}, fmt.Errorf("song was not found")
	}
	track := tracks[0]
	if err := os.MkdirAll(c.cacheDir(), 0o755); err != nil {
		return PreparedTrack{}, err
	}
	c.writeProgress("resolving", track.Title, 0, 0)

	body, err := c.postWeapi(musicBaseURL+"/weapi/song/enhance/player/url/v1", map[string]interface{}{
		"ids":        "[" + strconv.FormatInt(track.ID, 10) + "]",
		"level":      quality,
		"encodeType": "mp3",
	})
	if err != nil {
		return PreparedTrack{}, err
	}
	var urlResponse struct {
		Data []struct {
			URL   string `json:"url"`
			Size  int64  `json:"size"`
			Type  string `json:"type"`
			Level string `json:"level"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &urlResponse); err != nil {
		return PreparedTrack{}, err
	}
	if len(urlResponse.Data) == 0 || urlResponse.Data[0].URL == "" {
		c.writeProgress("unavailable", track.Title, 0, 0)
		return PreparedTrack{}, fmt.Errorf("song is unavailable or requires a valid Netease membership")
	}
	source := urlResponse.Data[0]
	extension := ".mp3"
	if parsed, parseErr := url.Parse(source.URL); parseErr == nil {
		if ext := filepath.Ext(parsed.Path); ext != "" {
			extension = strings.ToLower(ext)
		}
	}
	trackPath := filepath.Join(c.cacheDir(), strconv.FormatInt(track.ID, 10)+extension)
	c.writeProgress("downloading", track.Title, 0, 0)
	if err := downloadFile(source.URL, trackPath, track.Title, func(current, total int64) {
		c.writeProgress("downloading", track.Title, current, total)
	}); err != nil {
		return PreparedTrack{}, err
	}

	coverPath := filepath.Join(c.cacheDir(), strconv.FormatInt(track.ID, 10)+"-cover.jpg")
	if track.CoverURL != "" {
		if err := downloadFile(appendImageParam(track.CoverURL, 300), coverPath, track.Title, nil); err != nil {
			coverPath = ""
		}
	}

	lyricsPath := filepath.Join(c.cacheDir(), strconv.FormatInt(track.ID, 10)+".lrc")
	if err := c.writeLyrics(track.ID, lyricsPath); err != nil {
		lyricsPath = ""
	}
	c.writeProgress("complete", track.Title, 100, 100)
	prepared := PreparedTrack{
		Path: trackPath, Title: track.Title, Artist: track.Artist, Album: track.Album,
		Duration: track.Duration, CoverPath: coverPath, LyricsPath: lyricsPath,
		Quality: source.Level, ContentType: source.Type,
	}
	_ = writeAtomic(filepath.Join(c.cacheDir(), "current.tsv"), []byte(strings.Join([]string{
		trimField(prepared.Path), trimField(prepared.Title), trimField(prepared.Artist), trimField(prepared.Album),
		strconv.Itoa(prepared.Duration), trimField(prepared.CoverPath), trimField(prepared.LyricsPath),
		trimField(prepared.Quality), trimField(prepared.ContentType),
	}, "\t")+"\n"), 0o600)
	return prepared, nil
}

func (c *Client) writeLyrics(id int64, path string) error {
	body, err := c.postLinuxAPI(musicBaseURL+"/api/song/lyric", map[string]interface{}{
		"id": strconv.FormatInt(id, 10), "lv": "-1", "kv": "-1", "tv": "-1",
	})
	if err != nil {
		return err
	}
	var response struct {
		LRC struct {
			Lyric string `json:"lyric"`
		} `json:"lrc"`
	}
	if err := json.Unmarshal(body, &response); err != nil {
		return err
	}
	if strings.TrimSpace(response.LRC.Lyric) == "" {
		return fmt.Errorf("lyrics not found")
	}
	return writeAtomic(path, []byte(response.LRC.Lyric), 0o600)
}

func (c *Client) ClearCache() error {
	cache := filepath.Clean(c.cacheDir())
	root := filepath.Clean(c.dataDir)
	if cache == root || !strings.HasPrefix(cache, root+string(os.PathSeparator)) {
		return fmt.Errorf("invalid cache path")
	}
	return os.RemoveAll(cache)
}

func (c *Client) Resolve(id, quality string) (PreparedTrack, error) {
	if quality == "" {
		quality = "exhigh"
	}
	tracks, err := c.SongDetails([]string{id})
	if err != nil {
		return PreparedTrack{}, err
	}
	if len(tracks) == 0 {
		return PreparedTrack{}, fmt.Errorf("song was not found")
	}
	track := tracks[0]
	if err := os.MkdirAll(c.cacheDir(), 0o755); err != nil {
		return PreparedTrack{}, err
	}
	c.writeProgress("resolving", track.Title, 0, 0)
	body, err := c.postWeapi(musicBaseURL+"/weapi/song/enhance/player/url/v1", map[string]interface{}{
		"ids":        "[" + strconv.FormatInt(track.ID, 10) + "]",
		"level":      quality,
		"encodeType": "mp3",
	})
	if err != nil {
		return PreparedTrack{}, err
	}
	var urlResponse struct {
		Data []struct {
			URL   string `json:"url"`
			Size  int64  `json:"size"`
			Type  string `json:"type"`
			Level string `json:"level"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &urlResponse); err != nil {
		return PreparedTrack{}, err
	}
	if len(urlResponse.Data) == 0 || urlResponse.Data[0].URL == "" {
		c.writeProgress("unavailable", track.Title, 0, 0)
		return PreparedTrack{}, fmt.Errorf("song is unavailable or requires a valid Netease membership")
	}
	source := urlResponse.Data[0]
	coverPath := filepath.Join(c.cacheDir(), strconv.FormatInt(track.ID, 10)+"-cover.jpg")
	if track.CoverURL != "" {
		if err := downloadFile(appendImageParam(track.CoverURL, 300), coverPath, track.Title, nil); err != nil {
			coverPath = ""
		}
	}
	lyricsPath := filepath.Join(c.cacheDir(), strconv.FormatInt(track.ID, 10)+".lrc")
	if err := c.writeLyrics(track.ID, lyricsPath); err != nil {
		lyricsPath = ""
	}
	c.writeProgress("streaming", track.Title, 0, 0)
	prepared := PreparedTrack{
		StreamURL: source.URL, Title: track.Title, Artist: track.Artist, Album: track.Album,
		Duration: track.Duration, CoverPath: coverPath, LyricsPath: lyricsPath,
		Quality: source.Level, ContentType: source.Type,
	}
	_ = writeAtomic(filepath.Join(c.cacheDir(), "stream.tsv"), []byte(strings.Join([]string{
		trimField(prepared.StreamURL), trimField(prepared.Title), trimField(prepared.Artist), trimField(prepared.Album),
		strconv.Itoa(prepared.Duration), trimField(prepared.CoverPath), trimField(prepared.LyricsPath),
		trimField(prepared.Quality), trimField(prepared.ContentType),
	}, "\t")+"\n"), 0o600)
	return prepared, nil
}

func (c *Client) ResolveURL(id, quality string) (string, string, string, error) {
	if quality == "" {
		quality = "exhigh"
	}
	if _, err := strconv.ParseInt(id, 10, 64); err != nil {
		return "", "", "", fmt.Errorf("invalid song id: %w", err)
	}
	levels := []string{quality, "standard"}
	seenLevels := map[string]bool{}
	var lastErr error
	for index, level := range levels {
		if seenLevels[level] {
			continue
		}
		seenLevels[level] = true
		body, err := c.postWeapiWithTimeout(musicBaseURL+"/weapi/song/enhance/player/url/v1", map[string]interface{}{
			"ids":        "[" + id + "]",
			"level":      level,
			"encodeType": "mp3",
		}, 4*time.Second)
		if err == nil {
			var response struct {
				Data []struct {
					URL   string `json:"url"`
					Type  string `json:"type"`
					Level string `json:"level"`
				} `json:"data"`
			}
			if decodeErr := json.Unmarshal(body, &response); decodeErr != nil {
				lastErr = decodeErr
			} else if len(response.Data) == 0 || response.Data[0].URL == "" {
				lastErr = fmt.Errorf("song is unavailable or requires a valid Netease membership")
			} else {
				item := response.Data[0]
				playableURL, probeErr := choosePlayableURL(item.URL)
				if probeErr == nil {
					return playableURL, item.Level, item.Type, nil
				}
				lastErr = probeErr
			}
		} else {
			lastErr = err
		}
		if index+1 < len(levels) {
			time.Sleep(120 * time.Millisecond)
		}
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("stream URL was not returned")
	}
	return "", "", "", fmt.Errorf("unable to resolve a playable stream: %w", lastErr)
}

func usableFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Size() > 0
}

func (c *Client) Art(id, coverURL string) (string, error) {
	if err := os.MkdirAll(c.cacheDir(), 0o755); err != nil {
		return "", err
	}
	coverPath := filepath.Join(c.cacheDir(), id+"-cover.jpg")
	if usableFile(coverPath) {
		return coverPath, nil
	}
	if coverURL == "" {
		return "", fmt.Errorf("cover unavailable")
	}
	if err := downloadFile(appendImageParam(coverURL, 300), coverPath, "", nil); err != nil {
		return "", err
	}
	return coverPath, nil
}

func (c *Client) Lyrics(id string) (string, error) {
	if err := os.MkdirAll(c.cacheDir(), 0o755); err != nil {
		return "", err
	}
	lyricsPath := filepath.Join(c.cacheDir(), id+".lrc")
	if usableFile(lyricsPath) {
		return lyricsPath, nil
	}
	if err := c.writeLyricsFromID(id, lyricsPath); err != nil {
		return "", err
	}
	return lyricsPath, nil
}

func (c *Client) writeLyricsFromID(id, path string) error {
	numericID, err := strconv.ParseInt(id, 10, 64)
	if err != nil {
		return err
	}
	return c.writeLyrics(numericID, path)
}
