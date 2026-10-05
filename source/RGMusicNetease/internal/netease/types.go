package netease

type Account struct {
	LoggedIn    bool
	Nickname    string
	UID         int64
	VipType     int
	RedVipLevel int
	VipLevel    int
}

type Playlist struct {
	ID         int64
	Name       string
	TrackCount int
	CoverURL   string
	Creator    string
}

type Track struct {
	ID        int64
	Title     string
	Artist    string
	Album     string
	Duration  int
	CoverURL  string
	Available bool
}

type LoginStart struct {
	QRCodePath string
	URL        string
}

type LoginPoll struct {
	State   string
	Message string
	Account Account
}

type PreparedTrack struct {
	StreamURL   string
	Path        string
	Title       string
	Artist      string
	Album       string
	Duration    int
	CoverPath   string
	LyricsPath  string
	Quality     string
	ContentType string
}
