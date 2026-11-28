// Tall layout for Amethyst, layout key "tall-left": the main window on the
// left at full height, the rest stacked in equal rows on the right. It does
// what Amethyst's own tall does, as a custom layout so it can report itself
// in the log like the others. Amethyst finds it by its file name in
// ~/Library/Application Support/Amethyst/Layouts/ when it starts.
// ⌥⌃= and ⌥⌃- widen and narrow the main window, and dragging its edge does too.
const STEP = 0.05;
const MIN_RATIO = 0.2;
const MAX_RATIO = 0.8;

const clamp = (ratio) => Math.min(MAX_RATIO, Math.max(MIN_RATIO, ratio));

// Each arrangement is written to Amethyst's log, which Hammerspoon reads to
// know the layout of every Space: ~/.hammerspoon/amethyst-hud.lua.
const report = (layout, screenFrame) => console.log("amethyst-hud " + JSON.stringify({
    layout, x: screenFrame.x, y: screenFrame.y, w: screenFrame.width, h: screenFrame.height
}));

function layout() {
    return {
        name: "Tall",
        initialState: { mainPaneRatio: 0.5 },
        commands: {
            expandMain: {
                description: "Widen the main window",
                updateState: (state) => ({ ...state, mainPaneRatio: clamp(state.mainPaneRatio + STEP) })
            },
            shrinkMain: {
                description: "Narrow the main window",
                updateState: (state) => ({ ...state, mainPaneRatio: clamp(state.mainPaneRatio - STEP) })
            }
        },
        recommendMainPaneRatio: (ratio, state) => ({ ...state, mainPaneRatio: clamp(ratio) }),
        getFrameAssignments: (windows, screenFrame, state) => {
            report("tall-left", screenFrame);
            const frames = {};
            if (windows.length === 0) return frames;
            if (windows.length === 1) {
                frames[windows[0].id] = { x: screenFrame.x, y: screenFrame.y, width: screenFrame.width,
                                          height: screenFrame.height, isMain: true, unconstrainedDimension: "horizontal" };
                return frames;
            }
            const mainWidth = Math.round(screenFrame.width * state.mainPaneRatio);
            const stack = windows.length - 1;
            windows.forEach((window, index) => {
                if (index === 0) {
                    frames[window.id] = { x: screenFrame.x, y: screenFrame.y, width: mainWidth, height: screenFrame.height,
                                          isMain: true, unconstrainedDimension: "horizontal" };
                    return;
                }
                const row = index - 1;
                const top = Math.round(screenFrame.y + screenFrame.height * row / stack);
                const bottom = Math.round(screenFrame.y + screenFrame.height * (row + 1) / stack);
                frames[window.id] = { x: screenFrame.x + mainWidth, y: top, width: screenFrame.width - mainWidth,
                                      height: bottom - top, isMain: false, unconstrainedDimension: "horizontal" };
            });
            return frames;
        }
    };
}
