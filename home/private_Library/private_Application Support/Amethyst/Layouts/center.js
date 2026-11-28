// Center layout for Amethyst, layout key "center": Rectangle Pro's Almost
// Maximize, kept at full height. Amethyst finds it by its file name in
// ~/Library/Application Support/Amethyst/Layouts/ when it starts.
//
// Every window gets the same frame: full height, centred horizontally at WIDTH_SCALE
// of the screen, stacked like fullscreen; the focused window sits on top.
// 1.0 on both = fullscreen.
const WIDTH_SCALE = 0.9;
const HEIGHT_SCALE = 1.0;

// Each arrangement is written to Amethyst's log, which Hammerspoon reads to
// know the layout of every Space: ~/.hammerspoon/amethyst-hud.lua.
const report = (layout, screenFrame) => console.log("amethyst-hud " + JSON.stringify({
    layout, x: screenFrame.x, y: screenFrame.y, w: screenFrame.width, h: screenFrame.height
}));

function layout() {
    return {
        name: "Center",
        getFrameAssignments: (windows, screenFrame) => {
            report("center", screenFrame);
            const width = Math.round(screenFrame.width * WIDTH_SCALE);
            const height = Math.round(screenFrame.height * HEIGHT_SCALE);
            const frame = {
                x: Math.round(screenFrame.x + (screenFrame.width - width) / 2),
                y: Math.round(screenFrame.y + (screenFrame.height - height) / 2),
                width: width,
                height: height
            };
            return windows.reduce((frames, w) => ({ ...frames, [w.id]: frame }), {});
        }
    };
}
