// Floating layout for Amethyst, layout key "float": no layout. It places no
// window, so Amethyst leaves every window where it is. It does what
// Amethyst's own floating does, as a custom layout so it can report itself in
// the log like the others. Amethyst finds it by its file name in
// ~/Library/Application Support/Amethyst/Layouts/ when it starts.

// Each arrangement is written to Amethyst's log, which Hammerspoon reads to
// know the layout of every Space: ~/.hammerspoon/amethyst-hud.lua.
const report = (layout, screenFrame) => console.log("amethyst-hud " + JSON.stringify({
    layout, x: screenFrame.x, y: screenFrame.y, w: screenFrame.width, h: screenFrame.height
}));

function layout() {
    return {
        name: "Floating",
        getFrameAssignments: (windows, screenFrame) => {
            report("float", screenFrame);
            return {};
        }
    };
}
