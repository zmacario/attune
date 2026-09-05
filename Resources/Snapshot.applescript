-- Everything BitPerfect DX needs from Music, in one round trip: what's playing, where the
-- file lives, and the two settings that would quietly break bit-perfect playback.
--
-- Variable names are deliberately long: short ones collide with scripting terminology
-- (`st`, for one, does not compile inside a Music tell block).

tell application id "com.apple.Music"
    set playerStateText to (player state as text)
    set musicVolume to (get sound volume) as text
    set eqIsOn to (get EQ enabled) as text

    set trackName to ""
    set trackArtist to ""
    set trackRate to "0"
    set trackPath to ""
    set trackPosition to "0"

    try
        set theTrack to current track
        set trackName to (get name of theTrack)
        try
            set trackArtist to (get artist of theTrack)
        end try
        try
            set trackRate to (get sample rate of theTrack) as text
        end try
        try
            -- Streaming tracks have no location; this throws and we fall through.
            set trackPath to POSIX path of (get location of theTrack)
        end try
        try
            set trackPosition to (get player position) as text
        end try
    end try

    return playerStateText & linefeed & trackName & linefeed & trackArtist & linefeed & ¬
        trackRate & linefeed & trackPath & linefeed & trackPosition & linefeed & ¬
        musicVolume & linefeed & eqIsOn
end tell
