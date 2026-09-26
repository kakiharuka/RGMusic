package main

import (
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"

	"rgmusic-netease/internal/netease"
)

func fail(err error) {
	fmt.Fprintf(os.Stderr, "error\t%s\n", err.Error())
	os.Exit(1)
}

func main() {
	flags := flag.NewFlagSet("rgmusic-netease", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	dataDir := flags.String("data", "", "application data directory")
	outPath := flags.String("out", "", "output file")
	if err := flags.Parse(os.Args[1:]); err != nil {
		fail(err)
	}
	if *outPath != "" {
		output, err := os.Create(*outPath)
		if err != nil {
			fail(err)
		}
		defer output.Close()
		os.Stdout, os.Stderr = output, output
	}
	args := flags.Args()
	if len(args) == 0 {
		fail(fmt.Errorf("missing command"))
	}
	client, err := netease.New(*dataDir)
	if err != nil {
		fail(err)
	}

	switch args[0] {
	case "status":
		account, err := client.Status()
		if err != nil {
			fail(err)
		}
		if account.LoggedIn {
			fmt.Printf("logged_in\t%s\t%d\n", neteaseField(account.Nickname), account.UID)
		} else {
			fmt.Println("logged_out\t\t0")
		}
	case "login-start":
		start, err := client.LoginStart()
		if err != nil {
			fail(err)
		}
		fmt.Printf("waiting\t%s\t%s\n", neteaseField(start.QRCodePath), neteaseField(start.URL))
	case "login-poll":
		poll, err := client.LoginPoll()
		if err != nil {
			fail(err)
		}
		fmt.Printf("%s\t%s\t%s\t%d\n", poll.State, neteaseField(poll.Message), neteaseField(poll.Account.Nickname), poll.Account.UID)
	case "playlists":
		items, err := client.Playlists()
		if err != nil {
			fail(err)
		}
		for _, item := range items {
			fmt.Printf("playlist\t%d\t%d\t%s\t%s\t%s\n", item.ID, item.TrackCount, neteaseField(item.Creator), neteaseField(item.Name), neteaseField(item.CoverURL))
		}
	case "playlist":
		if len(args) < 2 {
			fail(fmt.Errorf("playlist id is required"))
		}
		items, err := client.PlaylistTracks(args[1])
		if err != nil {
			fail(err)
		}
		printTracks(items)
	case "search":
		if len(args) < 2 {
			fail(fmt.Errorf("search text is required"))
		}
		limit := 30
		if len(args) > 2 {
			if value, err := strconv.Atoi(args[2]); err == nil {
				limit = value
			}
		}
		items, err := client.SearchTracks(strings.Join(args[1:], " "), limit)
		if err != nil {
			fail(err)
		}
		printTracks(items)
	case "art":
		if len(args) < 2 {
			fail(fmt.Errorf("song id is required"))
		}
		coverURL := ""
		if len(args) > 2 {
			coverURL = args[2]
		}
		coverPath, err := client.Art(args[1], coverURL)
		if err != nil {
			fail(err)
		}
		fmt.Printf("art\t%s\n", neteaseField(coverPath))
	case "lyric":
		if len(args) < 2 {
			fail(fmt.Errorf("song id is required"))
		}
		lyricsPath, err := client.Lyrics(args[1])
		if err != nil {
			fail(err)
		}
		fmt.Printf("lyric\t%s\n", neteaseField(lyricsPath))
	case "stream":
		if len(args) < 2 {
			fail(fmt.Errorf("song id is required"))
		}
		quality := ""
		if len(args) > 2 {
			quality = args[2]
		}
		url, level, kind, err := client.ResolveURL(args[1], quality)
		if err != nil {
			fail(err)
		}
		fmt.Printf("streamurl\t%s\t%s\t%s\n", neteaseField(url), neteaseField(level), neteaseField(kind))
	case "resolve":
		if len(args) < 2 {
			fail(fmt.Errorf("song id is required"))
		}
		quality := ""
		if len(args) > 2 {
			quality = args[2]
		}
		item, err := client.Resolve(args[1], quality)
		if err != nil {
			fail(err)
		}
		fmt.Printf("stream\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\n", neteaseField(item.StreamURL), neteaseField(item.Title), neteaseField(item.Artist), neteaseField(item.Album), item.Duration, neteaseField(item.CoverPath), neteaseField(item.LyricsPath), neteaseField(item.Quality))
	case "prepare":
		if len(args) < 2 {
			fail(fmt.Errorf("song id is required"))
		}
		quality := ""
		if len(args) > 2 {
			quality = args[2]
		}
		item, err := client.Prepare(args[1], quality)
		if err != nil {
			fail(err)
		}
		fmt.Printf("ready\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\n",
			neteaseField(item.Path), neteaseField(item.Title), neteaseField(item.Artist), neteaseField(item.Album),
			item.Duration, neteaseField(item.CoverPath), neteaseField(item.LyricsPath), neteaseField(item.Quality))
	case "clear-cache":
		if err := client.ClearCache(); err != nil {
			fail(err)
		}
		fmt.Println("ok")
	case "logout":
		if err := client.Logout(); err != nil {
			fail(err)
		}
		fmt.Println("ok")
	default:
		fail(fmt.Errorf("unknown command: %s", args[0]))
	}
}

func printTracks(items []netease.Track) {
	for _, item := range items {
		available := "1"
		if !item.Available {
			available = "0"
		}
		fmt.Printf("track\t%d\t%s\t%s\t%s\t%d\t%s\t%s\n",
			item.ID, neteaseField(item.Title), neteaseField(item.Artist), neteaseField(item.Album),
			item.Duration, neteaseField(item.CoverURL), available)
	}
}

func neteaseField(value string) string {
	value = strings.ReplaceAll(value, "\t", " ")
	value = strings.ReplaceAll(value, "\r", " ")
	value = strings.ReplaceAll(value, "\n", " ")
	return strings.TrimSpace(value)
}
