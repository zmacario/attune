-- Everything Attune needs from Music, in one round trip: what's playing, where the
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
    set trackDuration to "0"
    set trackID to ""
    set nextID to ""
    set shuffleOn to "false"
    set nextName to ""
    set nextArtist to ""

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
        try
            set trackDuration to (get duration of theTrack) as text
        end try
        -- Identifies the track itself. Two entries can share a name and an artist while
        -- being different recordings in different formats; this tells them apart.
        try
            set trackID to (get persistent ID of theTrack)
        end try
    end try

    try
        set shuffleOn to (get shuffle enabled) as text
    end try

    -- What plays after this one, so its rate can be set before it starts. Only knowable in
    -- playlist order: with shuffle on the next index is not what comes, so nothing is
    -- reported rather than something wrong. Radio and other sources have no playlist at
    -- all, and fall through the same way.
    set repeatMode to "off"
    try
        set repeatMode to (song repeat as text)
    end try

    try
        if shuffleOn is "false" and repeatMode is not "one" then
            set thePlaylist to current playlist
            set theNextTrack to track ((index of (current track)) + 1) of thePlaylist
            set nextName to (get name of theNextTrack)
            try
                set nextArtist to (get artist of theNextTrack)
            end try
            try
                set nextID to (get persistent ID of theNextTrack)
            end try
        end if
    end try

    return playerStateText & linefeed & trackName & linefeed & trackArtist & linefeed & ¬
        trackRate & linefeed & trackPath & linefeed & trackPosition & linefeed & ¬
        musicVolume & linefeed & eqIsOn & linefeed & trackDuration & linefeed & ¬
        shuffleOn & linefeed & nextName & linefeed & nextArtist & linefeed & ¬
        trackID & linefeed & nextID
end tell
