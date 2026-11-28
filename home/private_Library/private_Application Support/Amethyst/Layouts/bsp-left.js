// BSP with the main window on the left, layout key "bsp-left". Amethyst finds
// it by its file name in ~/Library/Application Support/Amethyst/Layouts/ when
// it starts.
//
// The first window takes the left part at full height. Each window after it
// splits what's left, side by side then top and bottom in turn, the new
// window taking the right or lower half:
//   1 window  → full screen
//   2 windows → left | right
//   3 windows → left | right split top and bottom
//   4 windows → left | top right, and the bottom right split side by side
// ⌥⌃= and ⌥⌃- widen and narrow the left window, and dragging its edge does too.
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
        name: "BSP",
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
            report("bsp-left", screenFrame);
            const frames = {};
            let region = { x: screenFrame.x, y: screenFrame.y, width: screenFrame.width, height: screenFrame.height };
            windows.forEach((window, index) => {
                const isMain = index === 0;
                if (index === windows.length - 1) {
                    frames[window.id] = { ...region, isMain, unconstrainedDimension: "horizontal" };
                } else if (index % 2 === 0) {
                    const width = Math.round(region.width * (isMain ? state.mainPaneRatio : 0.5));
                    frames[window.id] = { x: region.x, y: region.y, width, height: region.height,
                                          isMain, unconstrainedDimension: "horizontal" };
                    region = { x: region.x + width, y: region.y, width: region.width - width, height: region.height };
                } else {
                    const height = Math.round(region.height / 2);
                    frames[window.id] = { x: region.x, y: region.y, width: region.width, height,
                                          isMain: false, unconstrainedDimension: "horizontal" };
                    region = { x: region.x, y: region.y + height, width: region.width, height: region.height - height };
                }
            });
            return frames;
        }
    };
}
