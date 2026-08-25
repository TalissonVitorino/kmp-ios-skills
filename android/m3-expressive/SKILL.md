---
name: m3-expressive
description: Material 3 Expressive design patterns for Jetpack Compose - expressive theming, motion physics, shape morphing, typography emphasis, color emphasis, and all 28 expressive components.
---

# Material 3 Expressive for Jetpack Compose

Material 3 Expressive extends Material 3 with spring-based motion, morphable shapes, emphasized type styles, a recoloured baseline palette, and a set of new components. This skill covers the Compose implementation in `androidx.compose.material3`.

> **Version gate — verified against material3 1.4.0 and 1.5.0-alpha26 (Aug 2026).**
>
> - **1.4.0 (stable, Compose BOM `2026.08.00`) exposes almost none of this.** `MaterialExpressiveTheme`, `expressiveLightColorScheme()`, `MotionScheme` / `MotionScheme.expressive()` / `MaterialTheme.motionScheme`, every `*Emphasized` type style, `Shapes.largeIncreased` / `extraLargeIncreased` / `extraExtraLarge`, `MediumFlexibleTopAppBar` / `LargeFlexibleTopAppBar` / `TwoRowsTopAppBar` / `FlexibleBottomAppBar` and `VerticalSlider` are all declared **`internal`** in 1.4.0. Only `WideNavigationRail` and `ShortNavigationBar` are public there.
> - **Everything else in this skill needs `1.5.0-alpha*`** — toggle buttons, `ButtonGroup`, `SplitButtonLayout`, the FAB menu and sized FABs, floating toolbars, wavy progress indicators, loading indicators, menu groups, the expanded search bars, `MaterialShapes`. In practice: use the alpha BOM or none of this resolves.
> - **Opt-in:** `ExperimentalMaterial3ExpressiveApi` is itself `internal` in 1.4.0, so the `@OptIn` cannot even be written there. From 1.5.0-alpha23 most expressive APIs graduated to stable; on 1.5.0-alpha26 only `LoadingIndicator` / `ContainedLoadingIndicator` and `MaterialShapes` / `Morph.toPath` / `RoundedPolygon.toShape` still require it. `AppBarWithSearch` and the deprecated `TopSearchBar` need `@OptIn(ExperimentalMaterial3Api::class)` instead — a different annotation. A redundant opt-in is harmless (an "unnecessary @OptIn" warning).
>
> Examples below are written for 1.5.0-alpha26 and keep the opt-in annotation. For general Compose state/recomposition work prefer `android-skills:compose`; for non-expressive theming see `compose-theming-styles`.

## Gradle Setup

```kotlin
// build.gradle.kts (app module)
plugins {
    id("org.jetbrains.kotlin.android")            // or kotlin("multiplatform")
    // Kotlin 2.x ships the Compose compiler as a Gradle plugin — versioned WITH Kotlin.
    // Do NOT use composeOptions { kotlinCompilerExtensionVersion } anymore (Kotlin 1.9-era, invalid on 2.x).
    id("org.jetbrains.kotlin.plugin.compose")
}

dependencies {
    // Expressive is alpha-only today — the stable BOM keeps these APIs internal.
    implementation(platform("androidx.compose:compose-bom-alpha:2026.08.00"))   // -> material3 1.5.0-alpha26
    // Stable alternative, without any expressive API:
    // implementation(platform("androidx.compose:compose-bom:2026.08.00"))      // -> material3 1.4.0

    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.animation:animation")
    implementation("androidx.compose.foundation:foundation")
    // MaterialShapes / Morph live in androidx.graphics:graphics-shapes, pulled in by material3.
}

android {
    buildFeatures {
        compose = true
    }
    // No composeOptions / kotlinCompilerExtensionVersion — the plugin.compose above handles it.
}
```

---

## 1. MaterialExpressiveTheme Setup

The entry point for M3 Expressive is `MaterialExpressiveTheme`, which replaces `MaterialTheme` and wires expressive defaults for color, motion, shapes, and typography.

### Complete Theme Setup

```kotlin
import androidx.compose.material3.*
import androidx.compose.runtime.Composable

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun AppTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = true,
    content: @Composable () -> Unit
) {
    val colorScheme = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalContext.current
            if (darkTheme) dynamicDarkColorScheme(context)
            else dynamicLightColorScheme(context)
        }
        // There is NO expressiveDarkColorScheme() — the expressive palette is light-only.
        darkTheme -> darkColorScheme()
        else -> expressiveLightColorScheme()
    }

    MaterialExpressiveTheme(
        colorScheme = colorScheme,
        motionScheme = MotionScheme.expressive(),
        shapes = Shapes(
            // Standard shapes
            small = RoundedCornerShape(8.dp),
            medium = RoundedCornerShape(16.dp),
            large = RoundedCornerShape(24.dp),
            extraLarge = RoundedCornerShape(32.dp),
            // Increased/extraExtraLarge params exist only on the 8-arg ctor (material3 1.5.0-alpha+).
            largeIncreased = RoundedCornerShape(28.dp),
            extraLargeIncreased = RoundedCornerShape(36.dp),
        ),
        typography = Typography(
            // Emphasized type styles for visual hierarchy
            displayLargeEmphasized = TextStyle(
                fontFamily = FontFamily.Default,
                fontWeight = FontWeight.Bold,
                fontSize = 57.sp,
                lineHeight = 64.sp,
                letterSpacing = (-0.25).sp,
            ),
            headlineLargeEmphasized = TextStyle(
                fontFamily = FontFamily.Default,
                fontWeight = FontWeight.SemiBold,
                fontSize = 32.sp,
                lineHeight = 40.sp,
            ),
        ),
        content = content
    )
}
```

### Theme API Signature

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun MaterialExpressiveTheme(
    colorScheme: ColorScheme? = null,     // null = expressiveLightColorScheme()
    motionScheme: MotionScheme? = null,   // null = MotionScheme.expressive()
    shapes: Shapes? = null,               // null = Shapes()      (standard defaults)
    typography: Typography? = null,       // null = Typography()  (standard defaults)
    content: @Composable () -> Unit,
)
```

The defaults above apply only to the **outermost** `MaterialExpressiveTheme`. A nested one (it tracks this with an internal composition local) resolves each `null` slot from the enclosing `MaterialTheme` instead, so nesting overrides only the slots you actually pass. Note also that `shapes`/`typography` currently fall back to the *standard* `Shapes()` / `Typography()` — only the colour and motion slots have distinct expressive defaults today.

### Accessing Theme Values

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ThemedContent() {
    val colors = MaterialTheme.colorScheme
    val typography = MaterialTheme.typography
    val shapes = MaterialTheme.shapes
    val motion = MaterialTheme.motionScheme

    Text(
        text = "Expressive Title",
        style = typography.displayLargeEmphasized,
        color = colors.primary
    )
}
```

---

## 2. Motion System

The motion system is the most transformative part of M3 Expressive. It replaces duration-based easing with **spring-based physics**, creating natural, responsive animations that feel alive.

### Core Concept: Spring Physics

Springs are defined by two parameters:
- **dampingRatio** - How quickly oscillation settles (0 = no damping/infinite bounce, 1 = critically damped/no overshoot)
- **stiffness** - How fast the spring moves toward its target (higher = faster)

```kotlin
import androidx.compose.animation.core.*

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun SpringExample() {
    var expanded by remember { mutableStateOf(false) }

    // Expressive spring with overshoot/bounce
    val size by animateFloatAsState(
        targetValue = if (expanded) 200f else 100f,
        animationSpec = spring(
            dampingRatio = Spring.DampingRatioMediumBouncy,  // 0.5f - visible bounce
            stiffness = Spring.StiffnessMedium               // 1500f
        ),
        label = "size"
    )

    Box(
        modifier = Modifier
            .size(size.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.primaryContainer)
            .clickable { expanded = !expanded }
    )
}
```

### MotionScheme Tokens

`MotionScheme.expressive()` provides six categories of motion tokens, split between **effects** (non-spatial, like fade/scale) and **spatial** (position/layout changes).

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun MotionTokensDemo() {
    val motion = MaterialTheme.motionScheme

    // === EFFECTS tokens (fade, scale, color change) ===

    // Fast effects: micro-interactions, toggles, checkboxes
    // ~150ms equivalent, stiff spring, minimal overshoot
    val fastEffectsSpec = motion.fastEffectsSpec<Float>()

    // Default effects: standard UI feedback, button presses
    // ~300ms equivalent, medium spring
    val defaultEffectsSpec = motion.defaultEffectsSpec<Float>()

    // Slow effects: emphasis animations, attention-drawing
    // ~500ms equivalent, gentle spring with bounce
    val slowEffectsSpec = motion.slowEffectsSpec<Float>()

    // === SPATIAL tokens (position, size, layout) ===

    // Fast spatial: small movements, tooltips, small menus
    // Quick with slight overshoot
    val fastSpatialSpec = motion.fastSpatialSpec<Float>()

    // Default spatial: navigation, expanding panels, sheets
    // Natural spring with moderate overshoot
    val defaultSpatialSpec = motion.defaultSpatialSpec<Float>()

    // Slow spatial: full-screen transitions, hero animations
    // Gentle spring with pronounced overshoot for drama
    val slowSpatialSpec = motion.slowSpatialSpec<Float>()
}
```

### Using Motion Tokens in Animations

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun AnimatedCard(isVisible: Boolean) {
    val motion = MaterialTheme.motionScheme

    // Use default spatial for position/size animations
    val offsetY by animateFloatAsState(
        targetValue = if (isVisible) 0f else 100f,
        animationSpec = motion.defaultSpatialSpec(),
        label = "offsetY"
    )

    // Use fast effects for opacity
    val alpha by animateFloatAsState(
        targetValue = if (isVisible) 1f else 0f,
        animationSpec = motion.fastEffectsSpec(),
        label = "alpha"
    )

    Card(
        modifier = Modifier
            .offset(y = offsetY.dp)
            .alpha(alpha)
    ) {
        Text("Animated Card")
    }
}
```

### Spring Constant Reference

Exact values of the `Spring` presets (`androidx.compose.animation.core`) — note that **Low**Bouncy is the *least* bouncy:

| Damping ratio | Value | Stiffness | Value |
|---|---|---|---|
| `DampingRatioHighBouncy` | `0.2f` | `StiffnessHigh` | `10000f` |
| `DampingRatioMediumBouncy` | `0.5f` | `StiffnessMedium` | `1500f` |
| `DampingRatioLowBouncy` | `0.75f` | `StiffnessMediumLow` | `400f` |
| `DampingRatioNoBouncy` | `1.0f` | `StiffnessLow` | `200f` |
| — | — | `StiffnessVeryLow` | `50f` |

Prefer `MaterialTheme.motionScheme` tokens over hand-rolled springs; reach for raw `spring()` only when a token has the wrong character.

### Shape Morphing Animations

True shape morphing uses `MaterialShapes` (35 predefined `RoundedPolygon`s) and `Morph` from `androidx.graphics:graphics-shapes`. `MaterialShapes`, `Morph.toPath` and `RoundedPolygon.toShape` are still `@ExperimentalMaterial3ExpressiveApi` on 1.5.0-alpha26, and are absent from 1.4.0.

Every `MaterialShapes` polygon is `RoundedPolygon.normalized()`, i.e. fitted into the **(0,0)–(1,1)** unit square, so `Morph.toPath()` over them emits a path in 0..1 and only needs scaling into the component's bounds. (The `scale(size.width / 2f, …)` + `translate(1f, 1f)` matrix in the AOSP shapes guide is for hand-built `RoundedPolygon(radius = 1f, centerX = 0f, centerY = 0f)` shapes, which live in -1..1 — applying it to `MaterialShapes` draws them at double size, off-centre.)

```kotlin
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.toPath
import androidx.compose.ui.graphics.Matrix
import androidx.compose.ui.graphics.Outline
import androidx.graphics.shapes.Morph

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
class MorphShape(private val morph: Morph, private val progress: Float) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val path = morph.toPath(progress)
        path.transform(Matrix().apply { scale(size.width, size.height) })
        return Outline.Generic(path)
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun MorphingIcon(isActive: Boolean) {
    val morph = remember { Morph(MaterialShapes.Cookie9Sided, MaterialShapes.Sunny) }
    val progress by animateFloatAsState(
        targetValue = if (isActive) 1f else 0f,
        animationSpec = MaterialTheme.motionScheme.defaultSpatialSpec(),
        label = "morph"
    )
    Box(
        Modifier
            .size(96.dp)
            .clip(MorphShape(morph, progress))
            .background(MaterialTheme.colorScheme.primaryContainer)
    )
}
```

For a single static polygon, `RoundedPolygon.toShape()` returns a `Shape` usable directly as a component `shape`. Animating a `RoundedCornerShape` corner size is a cheaper approximation when you only need pill ↔ rounded-rect:

```kotlin
val cornerPercent by animateIntAsState(
    targetValue = if (isActive) 50 else 16,
    animationSpec = MaterialTheme.motionScheme.defaultSpatialSpec(),
    label = "cornerMorph"
)
Button(onClick = { }, shape = RoundedCornerShape(cornerPercent)) { Text("Toggle") }
```

### Shared Element Transitions

```kotlin
import androidx.compose.animation.*

@OptIn(ExperimentalMaterial3ExpressiveApi::class, ExperimentalSharedTransitionApi::class)
@Composable
fun SharedElementDemo(
    sharedTransitionScope: SharedTransitionScope,
    animatedContentScope: AnimatedContentScope,
    item: Item,
    onClick: () -> Unit
) {
    with(sharedTransitionScope) {
        Card(
            modifier = Modifier
                .sharedElement(
                    // Parameter is `sharedContentState`, not `state`.
                    sharedContentState = rememberSharedContentState(key = "item-${item.id}"),
                    animatedVisibilityScope = animatedContentScope,
                    boundsTransform = { _, _ ->
                        // Use expressive spring for shared element bounds
                        spring(
                            dampingRatio = Spring.DampingRatioLowBouncy,
                            stiffness = Spring.StiffnessMediumLow
                        )
                    }
                )
                .clickable(onClick = onClick)
        ) {
            Text(item.title, style = MaterialTheme.typography.headlineMedium)
        }
    }
}
```

### Predictive Back Gesture Animations

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun PredictiveBackScreen(onBack: () -> Unit) {
    // Drive progress from the real gesture, not a free-floating state.
    var backProgress by remember { mutableFloatStateOf(0f) }

    PredictiveBackHandler(enabled = true) { events ->
        try {
            events.collect { backProgress = it.progress }   // BackEventCompat.progress, 0f..1f
            onBack()
        } finally {
            backProgress = 0f
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            // Gesture progress is already continuous — apply it directly in the
            // layer lambda instead of feeding it through animate*AsState.
            .graphicsLayer {
                val s = 1f - backProgress * 0.1f
                scaleX = s
                scaleY = s
                shape = RoundedCornerShape((backProgress * 24).dp)
                clip = true
            }
    ) {
        // Screen content
    }
}
```

`PredictiveBackHandler` comes from `androidx.activity.compose`; the gesture only produces progress when the app opts into predictive back (`android:enableOnBackInvokedCallback="true"` in the manifest, API 33+).

### Keyframe Animations

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun KeyframeAnimationDemo() {
    var trigger by remember { mutableStateOf(false) }

    val offsetX by animateFloatAsState(
        targetValue = if (trigger) 200f else 0f,
        animationSpec = keyframes {
            durationMillis = 600
            0f at 0 using EaseOut
            240f at 200 using EaseInOut  // Overshoot
            180f at 400 using EaseInOut  // Pull back
            200f at 600                   // Settle
        },
        label = "keyframeOffset"
    )

    Box(
        modifier = Modifier
            .offset(x = offsetX.dp)
            .size(60.dp)
            .background(
                MaterialTheme.colorScheme.tertiary,
                RoundedCornerShape(50)
            )
            .clickable { trigger = !trigger }
    )
}
```

---

## 3. Shape System

Two distinct things are called "shapes" in M3 Expressive: the corner-radius tokens on `MaterialTheme.shapes`, and the 35 predefined `MaterialShapes` polygons used for morphing (see section 2).

### Corner Shape Tokens

`Shapes` has exactly eight properties. There is **no** `smallIncreased`, `mediumIncreased`, or `full`.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ShapeTokensReference() {
    val shapes = MaterialTheme.shapes

    shapes.extraSmall          // 4.dp corner radius
    shapes.small               // 8.dp
    shapes.medium              // 12.dp
    shapes.large               // 16.dp
    shapes.extraLarge          // 28.dp

    // Increased variants (material3 1.5.0-alpha+; internal in 1.4.0)
    shapes.largeIncreased      // 20.dp
    shapes.extraLargeIncreased // 32.dp
    shapes.extraExtraLarge     // 48.dp

    // For a pill/circle use CircleShape (or RoundedCornerShape(50)) directly.
}
```

### Applying Shapes to Components

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ShapedComponents() {
    // Card with expressive increased shape
    Card(
        shape = MaterialTheme.shapes.largeIncreased,
        modifier = Modifier.fillMaxWidth()
    ) {
        Text(
            text = "Expressive Card",
            modifier = Modifier.padding(24.dp)
        )
    }

    Spacer(modifier = Modifier.height(16.dp))

    // Button with extra-large increased shape (very rounded)
    Button(
        onClick = { },
        shape = MaterialTheme.shapes.extraLargeIncreased
    ) {
        Text("Rounded Button")
    }

    Spacer(modifier = Modifier.height(16.dp))

    // Full pill shape — CircleShape, there is no shapes.full token
    AssistChip(
        onClick = { },
        label = { Text("Pill Chip") },
        shape = CircleShape
    )
}
```

### Cut Corner Shapes

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun CutCornerShapeDemo() {
    Surface(
        shape = CutCornerShape(topStart = 16.dp, bottomEnd = 16.dp),
        color = MaterialTheme.colorScheme.tertiaryContainer,
        modifier = Modifier.size(100.dp)
    ) {
        // Geometric, angular look
    }
}
```

---

## 4. Typography Emphasis

M3 Expressive adds **emphasized** variants to the type scale. Emphasized styles use heavier weights or variable font optical sizing to create stronger visual hierarchy.

### Emphasized Type Styles

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun TypographyEmphasisDemo() {
    val typography = MaterialTheme.typography

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        // Display - emphasized for hero headlines
        Text("Hero Title", style = typography.displayLargeEmphasized)
        Text("Display Medium", style = typography.displayMediumEmphasized)
        Text("Display Small", style = typography.displaySmallEmphasized)

        // Headline - emphasized for section headers
        Text("Section Header", style = typography.headlineLargeEmphasized)
        Text("Sub Section", style = typography.headlineMediumEmphasized)
        Text("Minor Section", style = typography.headlineSmallEmphasized)

        // Title - emphasized for card titles, list headers
        Text("Card Title", style = typography.titleLargeEmphasized)
        Text("List Title", style = typography.titleMediumEmphasized)
        Text("Small Title", style = typography.titleSmallEmphasized)

        // Body - emphasized for important body text
        Text("Important paragraph text.", style = typography.bodyLargeEmphasized)
        Text("Emphasized body.", style = typography.bodyMediumEmphasized)
        Text("Fine print emphasis.", style = typography.bodySmallEmphasized)

        // Label - emphasized for buttons, tabs
        Text("BUTTON", style = typography.labelLargeEmphasized)
        Text("TAB", style = typography.labelMediumEmphasized)
        Text("CAPTION", style = typography.labelSmallEmphasized)
    }
}
```

### Custom Emphasized Typography

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
fun createExpressiveTypography(): Typography {
    val baseFamily = FontFamily.Default

    return Typography(
        // Standard styles
        displayLarge = TextStyle(
            fontFamily = baseFamily,
            fontWeight = FontWeight.Normal,
            fontSize = 57.sp,
            lineHeight = 64.sp,
            letterSpacing = (-0.25).sp,
        ),
        // Emphasized counterpart - heavier weight, tighter tracking
        displayLargeEmphasized = TextStyle(
            fontFamily = baseFamily,
            fontWeight = FontWeight.Bold,
            fontSize = 57.sp,
            lineHeight = 64.sp,
            letterSpacing = (-0.5).sp,  // Tighter for emphasis
        ),
        headlineLarge = TextStyle(
            fontFamily = baseFamily,
            fontWeight = FontWeight.Normal,
            fontSize = 32.sp,
            lineHeight = 40.sp,
        ),
        headlineLargeEmphasized = TextStyle(
            fontFamily = baseFamily,
            fontWeight = FontWeight.SemiBold,
            fontSize = 32.sp,
            lineHeight = 40.sp,
            letterSpacing = (-0.2).sp,
        ),
    )
}
```

### Variable Font Emphasis

Variation axes are set on the `Font` itself, not on `TextStyle` — `TextStyle` has no `fontVariationSettings`. Use `FontVariation.Settings` (API 26+; ignored below that) and build a `FontFamily` whose entries differ by axis value.

```kotlin
import androidx.compose.ui.text.font.FontVariation

val expressiveFamily = FontFamily(
    Font(
        R.font.roboto_flex,
        weight = FontWeight.SemiBold,
        variationSettings = FontVariation.Settings(
            FontVariation.weight(600),
            FontVariation.width(105f),
            FontVariation.grade(50),        // slight optical weight bump on dark surfaces
        ),
    )
)

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun VariableFontEmphasis() {
    Text(
        text = "Variable Font Emphasis",
        style = MaterialTheme.typography.headlineLargeEmphasized.copy(
            fontFamily = expressiveFamily
        )
    )
}
```

`fontFeatureSettings` on `TextStyle` is a separate mechanism (OpenType features such as `"ss01"`), not variable-font axes.

---

## 5. Color System

M3 Expressive keeps the M3 colour *roles* unchanged and swaps the baseline palette: `expressiveLightColorScheme()` is a more saturated, tertiary-forward light scheme than `lightColorScheme()`.

### Expressive Color Schemes

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ColorSchemeDemo() {
    // The one expressive baseline scheme — takes no parameters.
    val lightColors = expressiveLightColorScheme()

    // There is NO expressiveDarkColorScheme(). Pair it with the standard
    // darkColorScheme() for dark mode; that is what the official sample does.
    val darkColors = darkColorScheme()
}
```

### Color Roles for Emphasis

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ColorEmphasisDemo() {
    val colors = MaterialTheme.colorScheme

    Column {
        // HIGH emphasis - Primary for main actions
        Button(
            onClick = { },
            colors = ButtonDefaults.buttonColors(
                containerColor = colors.primary,
                contentColor = colors.onPrimary
            )
        ) {
            Text("Primary Action")
        }

        // MEDIUM emphasis - Secondary for supporting actions
        Button(
            onClick = { },
            colors = ButtonDefaults.buttonColors(
                containerColor = colors.secondary,
                contentColor = colors.onSecondary
            )
        ) {
            Text("Secondary Action")
        }

        // ACCENT emphasis - Tertiary for expressive highlights
        Button(
            onClick = { },
            colors = ButtonDefaults.buttonColors(
                containerColor = colors.tertiary,
                contentColor = colors.onTertiary
            )
        ) {
            Text("Accent Action")
        }

        // SURFACE emphasis - Subtle, blended into background
        Surface(
            color = colors.surfaceContainerHighest,
            contentColor = colors.onSurface,
            shape = MaterialTheme.shapes.medium
        ) {
            Text("Surface Content", modifier = Modifier.padding(16.dp))
        }
    }
}
```

### Dynamic Color with Expressive Palettes

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun DynamicExpressiveColor() {
    val context = LocalContext.current
    val darkTheme = isSystemInDarkTheme()

    // Dynamic color extracts the palette from the user's wallpaper (API 31+).
    // Note: dynamic* schemes are the standard M3 tonal mapping — choosing them
    // opts out of the expressive baseline palette entirely.
    val colorScheme = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            if (darkTheme) dynamicDarkColorScheme(context)
            else dynamicLightColorScheme(context)
        }
        darkTheme -> darkColorScheme()
        else -> expressiveLightColorScheme()
    }

    MaterialExpressiveTheme(
        colorScheme = colorScheme,
        content = { /* app content */ }
    )
}
```

### Tertiary Color Usage

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun TertiaryAccentExample() {
    val colors = MaterialTheme.colorScheme

    // Tertiary is the "expressive accent" - use for:
    // - Highlighting active/selected states
    // - Drawing attention to new features
    // - Badges, tags, notification indicators

    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        // Active tab with tertiary accent
        Surface(
            color = colors.tertiaryContainer,
            shape = CircleShape
        ) {
            Text(
                "Active",
                color = colors.onTertiaryContainer,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
            )
        }

        // Inactive tab with surface
        Surface(
            color = colors.surfaceContainerHigh,
            shape = CircleShape
        ) {
            Text(
                "Inactive",
                color = colors.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
            )
        }
    }
}
```

---

## 6. Expressive Components

Signatures below are material3 1.5.0-alpha26 (see the version gate at the top — none of these are public in 1.4.0). The `@OptIn` annotation is kept throughout for uniformity; on alpha26 it is only load-bearing for the loading indicators and the `MaterialShapes` helpers.

### 6.1 ButtonGroup

A connected row of buttons that squeezes neighbours on press and spills extras into an overflow menu. `overflowIndicator` is a **required first parameter**, and the content lambda is a `ButtonGroupScope` — you declare items with `clickableItem` / `toggleableItem` / `customItem`, not by emitting arbitrary composables.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ButtonGroupDemo() {
    var selectedIndex by remember { mutableIntStateOf(0) }
    val options = listOf("Day", "Week", "Month")

    ButtonGroup(
        overflowIndicator = { menuState ->
            IconButton(onClick = { menuState.show() }) {
                Icon(Icons.Default.MoreVert, contentDescription = "More options")
            }
        },
        modifier = Modifier.fillMaxWidth(),
    ) {
        options.forEachIndexed { index, label ->
            toggleableItem(
                checked = index == selectedIndex,
                label = label,                       // plain String, not a composable
                onCheckedChange = { selectedIndex = index },
            )
        }
        clickableItem(onClick = { /* export */ }, label = "Export")
    }
}
```

`customItem(buttonGroupContent, menuContent)` takes an arbitrary composable plus the menu row it collapses into. `Modifier.animateWidth(interactionSource)` inside a custom item gives it the press-squeeze behaviour.

### 6.2 CircularWavyProgressIndicator

A circular progress indicator with a wavy, organic animation style.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun CircularWavyProgressDemo() {
    // Indeterminate - continuous wavy animation
    CircularWavyProgressIndicator(
        modifier = Modifier.size(48.dp),
        color = MaterialTheme.colorScheme.primary,
        trackColor = MaterialTheme.colorScheme.surfaceContainerHighest,
    )

    Spacer(modifier = Modifier.height(16.dp))

    // Determinate - wavy progress toward target
    var progress by remember { mutableFloatStateOf(0.65f) }

    CircularWavyProgressIndicator(
        progress = { progress },
        modifier = Modifier.size(48.dp),
        color = MaterialTheme.colorScheme.tertiary,
        trackColor = MaterialTheme.colorScheme.tertiaryContainer,
    )
}
```

### 6.3 ContainedLoadingIndicator

The morphing loading indicator drawn inside a filled container. Parameters are `containerColor` / `indicatorColor` / `containerShape` — there is no `color` or `shape`. Still `@ExperimentalMaterial3ExpressiveApi` on 1.5.0-alpha26.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ContainedLoadingDemo(progress: () -> Float) {
    // Indeterminate
    ContainedLoadingIndicator(
        containerColor = MaterialTheme.colorScheme.primaryContainer,
        indicatorColor = MaterialTheme.colorScheme.onPrimaryContainer,
        containerShape = LoadingIndicatorDefaults.containerShape,
    )

    // Determinate — pass progress as a lambda so it is read in the draw phase
    ContainedLoadingIndicator(progress = progress)
}
```

`polygons: List<RoundedPolygon>` overrides the shape sequence it morphs through; `LoadingIndicatorDefaults.IndeterminateIndicatorPolygons` is the default.

### 6.4 DropdownMenuGroup

A grouped, separately-shaped block of menu items. The first parameter is `shapes: MenuGroupShapes` (required, no default) — get it from `MenuDefaults.groupShape(index, count)` so consecutive groups round correctly. There is **no `label` parameter**; emit `MenuDefaults.DropdownMenuGroupLabel { ... }` as the group's first child.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun DropdownMenuGroupDemo() {
    var expanded by remember { mutableStateOf(false) }

    Box {
        IconButton(onClick = { expanded = true }) {
            Icon(Icons.Default.MoreVert, contentDescription = "Menu")
        }

        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuGroup(shapes = MenuDefaults.groupShape(index = 0, count = 2)) {
                MenuDefaults.DropdownMenuGroupLabel { Text("Edit") }
                DropdownMenuItem(
                    text = { Text("Cut") },
                    onClick = { expanded = false },
                    leadingIcon = { Icon(Icons.Default.ContentCut, null) }
                )
                DropdownMenuItem(
                    text = { Text("Copy") },
                    onClick = { expanded = false },
                    leadingIcon = { Icon(Icons.Default.ContentCopy, null) }
                )
            }
            DropdownMenuGroup(shapes = MenuDefaults.groupShape(index = 1, count = 2)) {
                MenuDefaults.DropdownMenuGroupLabel { Text("Format") }
                DropdownMenuItem(text = { Text("Bold") }, onClick = { expanded = false })
                DropdownMenuItem(text = { Text("Italic") }, onClick = { expanded = false })
            }
        }
    }
}
```

### 6.5 DropdownMenuPopup

The unstyled popup container behind `DropdownMenu` — no surface, elevation or padding of its own. Use it when you need a menu positioned by a custom `DropdownMenuPopupPositionProvider` (from `rememberDropdownMenuPopupPositionProvider(MenuAnchorPosition…)`) but want to supply your own container; otherwise prefer `DropdownMenu`.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun DropdownMenuPopupDemo() {
    var showPopup by remember { mutableStateOf(false) }

    Box {
        Button(onClick = { showPopup = true }) { Text("Show Popup") }

        DropdownMenuPopup(
            expanded = showPopup,
            onDismissRequest = { showPopup = false },
        ) {
            DropdownMenuItem(
                text = { Text("Share") },
                onClick = { showPopup = false },
                leadingIcon = { Icon(Icons.Default.Share, null) }
            )
            DropdownMenuItem(
                text = { Text("Delete") },
                onClick = { showPopup = false },
                leadingIcon = { Icon(Icons.Default.Delete, null) }
            )
        }
    }
}
```

### 6.6 ElevatedToggleButton

A toggle button with elevation changes to indicate state.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ElevatedToggleButtonDemo() {
    var checked by remember { mutableStateOf(false) }

    ElevatedToggleButton(
        checked = checked,
        onCheckedChange = { checked = it },
        icon = {
            Icon(
                imageVector = if (checked) Icons.Filled.Bookmark else Icons.Outlined.BookmarkBorder,
                contentDescription = null,
            )
        },
    ) {
        Text(if (checked) "Saved" else "Save")
    }
}
```

### 6.7 ExpandedDockedSearchBarWithGap

The expanded (results) half of a docked search bar, drawn as a dropdown separated from the input field by a gap. It is state-driven: the first parameter is a hoisted `SearchBarState`, and there is **no `expanded` / `onExpandedChange` pair**. The current `SearchBarDefaults.InputField` overload takes a `TextFieldState` plus the same `SearchBarState`; the `query`/`onQueryChange`/`expanded` overload is deprecated.

Pair it with `AppBarWithSearch` for the collapsed input (`TopSearchBar` is deprecated in favour of it); `ExpandedFullScreenSearchBar` is the full-screen alternative. `AppBarWithSearch` is gated on `ExperimentalMaterial3Api`, **not** the expressive annotation — opt into both.

```kotlin
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ExpandedDockedSearchBarDemo(suggestions: List<String>) {
    val searchBarState = rememberSearchBarState()
    val textFieldState = rememberTextFieldState()
    val scope = rememberCoroutineScope()

    val inputField = @Composable {
        SearchBarDefaults.InputField(
            textFieldState = textFieldState,
            searchBarState = searchBarState,
            onSearch = { scope.launch { searchBarState.animateToCollapsed() } },
            placeholder = { Text("Search...") },
            leadingIcon = { Icon(Icons.Default.Search, "Search") },
        )
    }

    AppBarWithSearch(state = searchBarState, inputField = inputField)

    ExpandedDockedSearchBarWithGap(
        state = searchBarState,
        inputField = inputField,
    ) {
        LazyColumn {
            items(suggestions) { suggestion ->
                ListItem(
                    headlineContent = { Text(suggestion) },
                    leadingContent = { Icon(Icons.Default.History, null) },
                    modifier = Modifier.clickable {
                        textFieldState.setTextAndPlaceCursorAtEnd(suggestion)
                        scope.launch { searchBarState.animateToCollapsed() }
                    }
                )
            }
        }
    }
}
```

### 6.8 FlexibleBottomAppBar

A bottom app bar that can expand and collapse with spring animations.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun FlexibleBottomAppBarDemo() {
    val scrollBehavior = BottomAppBarDefaults.exitAlwaysScrollBehavior()

    Scaffold(
        bottomBar = {
            FlexibleBottomAppBar(
                scrollBehavior = scrollBehavior,
                horizontalArrangement = Arrangement.SpaceEvenly,
            ) {
                IconButton(onClick = { }) {
                    Icon(Icons.Default.Home, contentDescription = "Home")
                }
                IconButton(onClick = { }) {
                    Icon(Icons.Default.Search, contentDescription = "Search")
                }
                IconButton(onClick = { }) {
                    Icon(Icons.Default.Notifications, contentDescription = "Notifications")
                }
                IconButton(onClick = { }) {
                    Icon(Icons.Default.Person, contentDescription = "Profile")
                }
            }
        }
    ) { padding ->
        LazyColumn(
            contentPadding = padding,
            modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection)
        ) {
            items(50) { Text("Item $it", modifier = Modifier.padding(16.dp)) }
        }
    }
}
```

### 6.9 FloatingActionButtonMenu + FloatingActionButtonMenuItem

An expandable FAB that reveals a menu of actions with spring animations.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun FabMenuDemo() {
    var expanded by rememberSaveable { mutableStateOf(false) }

    Scaffold(
        floatingActionButton = {
            FloatingActionButtonMenu(
                expanded = expanded,
                button = {
                    FloatingActionButton(
                        onClick = { expanded = !expanded },
                        containerColor = MaterialTheme.colorScheme.primaryContainer,
                        contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                    ) {
                        Icon(
                            imageVector = if (expanded) Icons.Default.Close else Icons.Default.Add,
                            contentDescription = if (expanded) "Close" else "Add"
                        )
                    }
                }
            ) {
                FloatingActionButtonMenuItem(
                    onClick = { expanded = false },
                    icon = { Icon(Icons.Default.CameraAlt, "Camera") },
                    text = { Text("Take Photo") },
                )
                FloatingActionButtonMenuItem(
                    onClick = { expanded = false },
                    icon = { Icon(Icons.Default.Image, "Gallery") },
                    text = { Text("From Gallery") },
                )
                FloatingActionButtonMenuItem(
                    onClick = { expanded = false },
                    icon = { Icon(Icons.Default.Description, "Document") },
                    text = { Text("Upload File") },
                )
            }
        }
    ) { padding ->
        Box(Modifier.padding(padding))
    }
}
```

### 6.10 HorizontalFloatingToolbar

A floating toolbar that hovers over content with horizontal layout.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun HorizontalFloatingToolbarDemo() {
    var visible by remember { mutableStateOf(true) }

    Box(modifier = Modifier.fillMaxSize()) {
        // Content behind toolbar
        Text("Select text to show toolbar")

        AnimatedVisibility(
            visible = visible,
            modifier = Modifier.align(Alignment.BottomCenter).padding(16.dp),
            enter = fadeIn() + slideInVertically { it },
            exit = fadeOut() + slideOutVertically { it }
        ) {
            HorizontalFloatingToolbar(
                expanded = true,
                content = {
                    IconButton(onClick = { }) {
                        Icon(Icons.Default.FormatBold, "Bold")
                    }
                    IconButton(onClick = { }) {
                        Icon(Icons.Default.FormatItalic, "Italic")
                    }
                    IconButton(onClick = { }) {
                        Icon(Icons.Default.FormatUnderlined, "Underline")
                    }
                    VerticalDivider(modifier = Modifier.height(24.dp))
                    IconButton(onClick = { }) {
                        Icon(Icons.Default.FormatColorText, "Color")
                    }
                }
            )
        }
    }
}
```

### 6.11 LargeExtendedFloatingActionButton

An extra-large FAB with text and icon for primary screen actions.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun LargeExtendedFabDemo() {
    LargeExtendedFloatingActionButton(
        onClick = { /* action */ },
        icon = {
            Icon(
                Icons.Default.Edit,
                contentDescription = "Compose"
            )
        },
        text = { Text("Compose") },
        containerColor = MaterialTheme.colorScheme.primaryContainer,
        contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
    )
}
```

### 6.12 LargeFlexibleTopAppBar

A top app bar that supports large titles and collapses on scroll with spring physics.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun LargeFlexibleTopAppBarDemo() {
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()

    Scaffold(
        topBar = {
            LargeFlexibleTopAppBar(
                title = { Text("Messages") },
                subtitle = { Text("3 unread") },
                navigationIcon = {
                    IconButton(onClick = { }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back")
                    }
                },
                actions = {
                    IconButton(onClick = { }) {
                        Icon(Icons.Default.Search, "Search")
                    }
                },
                scrollBehavior = scrollBehavior,
            )
        },
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection)
    ) { padding ->
        LazyColumn(contentPadding = padding) {
            items(30) { index ->
                ListItem(headlineContent = { Text("Message $index") })
            }
        }
    }
}
```

### 6.13 LinearWavyProgressIndicator

A linear progress indicator with a wavy track. Do not force a small `height()` — the wave needs room for its amplitude; tune `wavelength`, `amplitude` and `stroke` instead.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun LinearWavyProgressDemo(progress: () -> Float) {
    // Indeterminate
    LinearWavyProgressIndicator(
        modifier = Modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.primary,
        trackColor = MaterialTheme.colorScheme.surfaceContainerHighest,
    )

    Spacer(modifier = Modifier.height(16.dp))

    // Determinate. On this overload `amplitude` is a (Float) -> Float of progress —
    // the default flattens the wave as it approaches 100%.
    LinearWavyProgressIndicator(
        progress = progress,
        modifier = Modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.tertiary,
        trackColor = MaterialTheme.colorScheme.tertiaryContainer,
    )
}
```

### 6.14 LoadingIndicator

The uncontained morphing indicator — same shape sequence as `ContainedLoadingIndicator`, no container. Also still `@ExperimentalMaterial3ExpressiveApi`.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun LoadingIndicatorDemo(progress: () -> Float) {
    LoadingIndicator(color = MaterialTheme.colorScheme.primary)   // indeterminate
    LoadingIndicator(progress = progress)                         // determinate
}
```

### 6.15 MaterialExpressiveTheme

See Section 1 above for complete theme setup.

### 6.16 MediumExtendedFloatingActionButton

A medium-sized FAB with text and icon.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun MediumExtendedFabDemo() {
    MediumExtendedFloatingActionButton(
        onClick = { /* action */ },
        icon = {
            Icon(Icons.Default.Add, contentDescription = "Add")
        },
        text = { Text("New Item") },
    )
}
```

### 6.17 MediumFlexibleTopAppBar

A medium-height flexible top app bar with spring-based collapse.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun MediumFlexibleTopAppBarDemo() {
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()

    Scaffold(
        topBar = {
            MediumFlexibleTopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(onClick = { }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back")
                    }
                },
                scrollBehavior = scrollBehavior,
            )
        },
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection)
    ) { padding ->
        LazyColumn(contentPadding = padding) {
            items(20) { ListItem(headlineContent = { Text("Setting $it") }) }
        }
    }
}
```

### 6.18 MediumFloatingActionButton

A medium-sized FAB without text, between standard and large sizes.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun MediumFabDemo() {
    MediumFloatingActionButton(
        onClick = { /* action */ },
        containerColor = MaterialTheme.colorScheme.tertiaryContainer,
        contentColor = MaterialTheme.colorScheme.onTertiaryContainer,
    ) {
        Icon(Icons.Default.Navigation, contentDescription = "Navigate")
    }
}
```

### 6.19 OutlinedToggleButton

A toggle button with an outline style.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun OutlinedToggleButtonDemo() {
    var checked by remember { mutableStateOf(false) }

    OutlinedToggleButton(
        checked = checked,
        onCheckedChange = { checked = it },
        icon = {
            Icon(
                imageVector = if (checked) Icons.Filled.Favorite else Icons.Outlined.FavoriteBorder,
                contentDescription = null,
            )
        },
    ) {
        Text(if (checked) "Liked" else "Like")
    }
}
```

### 6.20 SmallExtendedFloatingActionButton

A compact FAB with text for secondary actions.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun SmallExtendedFabDemo() {
    SmallExtendedFloatingActionButton(
        onClick = { /* action */ },
        icon = {
            Icon(Icons.Default.FilterList, contentDescription = "Filter")
        },
        text = { Text("Filter") },
    )
}
```

### 6.21 SplitButtonLayout

A button split into two actionable segments (main action + dropdown/secondary).

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun SplitButtonDemo() {
    var expanded by remember { mutableStateOf(false) }

    SplitButtonLayout(
        leadingButton = {
            SplitButtonDefaults.LeadingButton(
                onClick = { /* main action: Save */ },
            ) {
                Icon(Icons.Default.Save, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Save")
            }
        },
        trailingButton = {
            // Two overloads: (onClick, ...) and (checked, onCheckedChange, ...).
            // Do not mix onClick with checked — that resolves to neither.
            SplitButtonDefaults.TrailingButton(
                checked = expanded,
                onCheckedChange = { expanded = it },
            ) {
                Icon(Icons.Default.ArrowDropDown, contentDescription = "More save options")
            }
        }
    )

    DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
        DropdownMenuItem(
            text = { Text("Save as Draft") },
            onClick = { expanded = false }
        )
        DropdownMenuItem(
            text = { Text("Save and Publish") },
            onClick = { expanded = false }
        )
    }
}
```

### 6.22 ToggleButton (Filled)

The filled toggle button; `ElevatedToggleButton`, `FilledTonalToggleButton` and `OutlinedToggleButton` (6.6 / 6.24 / 6.19) share its signature and differ only in defaults. All four take a dedicated optional `icon: @Composable (() -> Unit)?` slot — pass the icon there rather than inside `content`, so the leading-icon padding is correct — plus `buttonSize: ToggleButtonSize` (`ExtraSmall`/`Small`/`Medium`/`Large`/`ExtraLarge`) and `shapes: ToggleButtonShapes`, which carries the checked/pressed shape morph. `content` is a `RowScope`.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ToggleButtonDemo() {
    var checked by remember { mutableStateOf(false) }

    ToggleButton(
        checked = checked,
        onCheckedChange = { checked = it },
        icon = {
            Icon(
                imageVector = if (checked) Icons.Filled.Mic else Icons.Filled.MicOff,
                contentDescription = null,
            )
        },
    ) {
        Text(if (checked) "Muted" else "Unmuted")
    }
}
```

### 6.23 ToggleFloatingActionButton

A FAB that animates size, corner radius and colour across a checked transition — typically the button slot of a `FloatingActionButtonMenu`. `containerColor`, `containerSize` and `containerCornerRadius` are **functions of the 0f..1f checked progress**, not plain values; there is no `checkedContainerColor`. Content runs in `ToggleFloatingActionButtonScope`, which exposes `checkedProgress` for cross-fading icons.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ToggleFabDemo() {
    var checked by rememberSaveable { mutableStateOf(false) }

    ToggleFloatingActionButton(
        checked = checked,
        onCheckedChange = { checked = it },
        containerColor = ToggleFloatingActionButtonDefaults.containerColor(
            initialColor = MaterialTheme.colorScheme.primaryContainer,
            finalColor = MaterialTheme.colorScheme.tertiaryContainer,
        ),
    ) {
        // No animateVectorAsState in Compose — cross-fade two icons on progress instead.
        Icon(
            painter = rememberVectorPainter(Icons.Filled.Add),
            contentDescription = null,
            modifier = Modifier.graphicsLayer { alpha = 1f - checkedProgress },
        )
        Icon(
            painter = rememberVectorPainter(Icons.Filled.Close),
            contentDescription = null,
            modifier = Modifier.graphicsLayer { alpha = checkedProgress },
        )
    }
}
```

`Modifier.animateIcon({ checkedProgress })` on `ToggleFloatingActionButtonDefaults` is the packaged version of that cross-fade (it takes a `() -> Float` lambda, not the `Float` itself) (it also animates icon colour and size); `containerSizeMedium()` / `containerSizeLarge()` and the matching `containerCornerRadius*()` give the standard size ramps.

### 6.24 FilledTonalToggleButton

A toggle button using tonal (filled tonal) styling. Renamed from `TonalToggleButton` in 1.5.0-alpha25 — the old name still resolves but is `@Deprecated`, is still experimental, and lacks the `buttonSize` / `icon` parameters.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun FilledTonalToggleButtonDemo() {
    var checked by remember { mutableStateOf(false) }

    FilledTonalToggleButton(
        checked = checked,
        onCheckedChange = { checked = it },
        icon = {
            Icon(
                imageVector = if (checked) Icons.Filled.Notifications else Icons.Outlined.Notifications,
                contentDescription = null,
            )
        },
    ) {
        Text(if (checked) "On" else "Off")
    }
}
```

### 6.25 TwoRowsTopAppBar

A top app bar supporting two rows of content -- title and secondary information. Unlike the flexible bars, its `title` and `subtitle` slots are `@Composable (expanded: Boolean) -> Unit`, so you can render differently in the collapsed and expanded rows; ignoring the parameter (as below) is valid.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun TwoRowsTopAppBarDemo() {
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()

    Scaffold(
        topBar = {
            TwoRowsTopAppBar(
                title = { Text("Inbox") },
                subtitle = { Text("12 new messages") },
                navigationIcon = {
                    IconButton(onClick = { }) {
                        Icon(Icons.Default.Menu, "Menu")
                    }
                },
                actions = {
                    IconButton(onClick = { }) {
                        Icon(Icons.Default.Search, "Search")
                    }
                    IconButton(onClick = { }) {
                        Icon(Icons.Default.MoreVert, "More")
                    }
                },
                scrollBehavior = scrollBehavior,
            )
        },
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection)
    ) { padding ->
        LazyColumn(contentPadding = padding) {
            items(50) { ListItem(headlineContent = { Text("Email $it") }) }
        }
    }
}
```

### 6.26 VerticalFloatingToolbar

A floating toolbar arranged vertically, suitable for side-panel actions.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun VerticalFloatingToolbarDemo() {
    Box(modifier = Modifier.fillMaxSize()) {
        VerticalFloatingToolbar(
            modifier = Modifier.align(Alignment.CenterEnd).padding(16.dp),
            expanded = true,
            content = {
                IconButton(onClick = { }) {
                    Icon(Icons.Default.ZoomIn, "Zoom In")
                }
                IconButton(onClick = { }) {
                    Icon(Icons.Default.ZoomOut, "Zoom Out")
                }
                // Content is a ColumnScope -> separate rows with HorizontalDivider
                HorizontalDivider(modifier = Modifier.width(24.dp))
                IconButton(onClick = { }) {
                    Icon(Icons.Default.Fullscreen, "Fullscreen")
                }
                IconButton(onClick = { }) {
                    Icon(Icons.Default.RotateRight, "Rotate")
                }
            }
        )
    }
}
```

### 6.27 VerticalSlider

A vertical slider for volume, brightness, or similar controls. It is **state-based only** — there is no `value` / `onValueChange` / `valueRange` overload. Hoist a `SliderState` (`rememberSliderState(value, steps, trackRange)`) and read `state.value`; the `onValueChange` parameter is an optional side-channel, not the source of truth. `topToBottom` flips the direction.

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun VerticalSliderDemo() {
    val sliderState = rememberSliderState(value = 0.5f, trackRange = 0f..1f)

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Icon(Icons.Default.VolumeUp, "Volume", modifier = Modifier.size(24.dp))

        VerticalSlider(
            state = sliderState,
            modifier = Modifier.height(200.dp),
            colors = SliderDefaults.colors(
                thumbColor = MaterialTheme.colorScheme.primary,
                activeTrackColor = MaterialTheme.colorScheme.primary,
                inactiveTrackColor = MaterialTheme.colorScheme.surfaceContainerHighest,
            ),
        )

        Text(
            text = "${(sliderState.value * 100).toInt()}%",
            style = MaterialTheme.typography.labelMedium
        )
    }
}
```

---

## 7. Accessibility

### Touch Target Sizes

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun AccessibleToggleButton() {
    var checked by remember { mutableStateOf(false) }

    // All expressive components enforce minimum 48dp touch targets
    // by default, but verify custom layouts

    ToggleButton(
        checked = checked,
        onCheckedChange = { checked = it },
        modifier = Modifier.defaultMinSize(minWidth = 48.dp, minHeight = 48.dp)
    ) {
        Icon(Icons.Default.Star, contentDescription = "Toggle favorite")
    }
}
```

### Contrast Ratios with Expressive Colors

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun AccessibleExpressiveColors() {
    val colors = MaterialTheme.colorScheme

    // Expressive color schemes maintain WCAG AA contrast ratios:
    // - on* colors guarantee 4.5:1 against their paired surface
    // - Container/onContainer pairs guarantee 3:1 minimum

    // ✅ CORRECT: Use paired color roles
    Surface(color = colors.primaryContainer) {
        Text("Accessible", color = colors.onPrimaryContainer)
    }

    // ❌ WRONG: Mixing unpaired color roles may fail contrast
    Surface(color = colors.primaryContainer) {
        Text("May not be accessible", color = colors.onTertiaryContainer)
    }
}
```

### Screen Reader Support

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ScreenReaderFriendlyComponents() {
    // Toggle buttons announce state automatically
    var isMuted by remember { mutableStateOf(false) }

    ToggleButton(
        checked = isMuted,
        onCheckedChange = { isMuted = it },
        modifier = Modifier.semantics {
            stateDescription = if (isMuted) "Muted" else "Unmuted"
            contentDescription = "Microphone toggle"
        }
    ) {
        Icon(
            imageVector = if (isMuted) Icons.Filled.MicOff else Icons.Filled.Mic,
            contentDescription = null // Handled by parent semantics
        )
    }

    // Progress indicators should announce progress
    CircularWavyProgressIndicator(
        progress = { 0.65f },
        modifier = Modifier.semantics {
            contentDescription = "Loading, 65 percent complete"
        }
    )
}
```

### Reduced Motion Support

Compose has **no `LocalReduceMotion`** on Android (that composition local only exists in Wear Compose). Read the platform setting yourself: Android exposes "Remove animations" as `Settings.Global.ANIMATOR_DURATION_SCALE == 0f`. Hoist it into your own composition local rather than querying it per component.

```kotlin
val LocalReduceMotion = staticCompositionLocalOf { false }

@Composable
fun rememberReduceMotion(): Boolean {
    val resolver = LocalContext.current.contentResolver
    return remember(resolver) {
        Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ReducedMotionAware() {
    val reduceMotion = LocalReduceMotion.current      // provided at the theme root
    val motion = MaterialTheme.motionScheme

    var expanded by remember { mutableStateOf(false) }

    val height by animateDpAsState(
        targetValue = if (expanded) 200.dp else 80.dp,
        animationSpec = if (reduceMotion) snap() else motion.defaultSpatialSpec(),
        label = "expandHeight"
    )

    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .height(height)
            .clickable { expanded = !expanded },
        shape = MaterialTheme.shapes.large
    ) {
        Text("Tap to expand", modifier = Modifier.padding(16.dp))
    }
}
```

### Semantic Descriptions for Animated Components

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun SemanticAnimatedFab() {
    var expanded by rememberSaveable { mutableStateOf(false) }

    FloatingActionButtonMenu(
        expanded = expanded,
        button = {
            FloatingActionButton(
                onClick = { expanded = !expanded },
                modifier = Modifier.semantics {
                    contentDescription = if (expanded) "Close action menu" else "Open action menu"
                    role = Role.Button
                }
            ) {
                Icon(
                    if (expanded) Icons.Default.Close else Icons.Default.Add,
                    contentDescription = null
                )
            }
        },
        modifier = Modifier.semantics {
            if (expanded) {
                liveRegion = LiveRegionMode.Polite
            }
        }
    ) {
        FloatingActionButtonMenuItem(
            onClick = { expanded = false },
            icon = { Icon(Icons.Default.CameraAlt, null) },
            text = { Text("Take Photo") },
            modifier = Modifier.semantics {
                contentDescription = "Take a photo"
            }
        )
    }
}
```

---

## 8. Performance Best Practices

### Lazy Composition for Animated Components

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun PerformantAnimatedList(items: List<Item>) {
    // ✅ CORRECT: Use LazyColumn with stable keys for animated items
    LazyColumn {
        items(
            items = items,
            key = { it.id }  // Stable keys prevent unnecessary recomposition
        ) { item ->
            AnimatedItem(item = item)
        }
    }
}

@Composable
fun AnimatedItem(item: Item) {
    var visible by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        visible = true
    }

    AnimatedVisibility(visible = visible) {
        ListItem(headlineContent = { Text(item.title) })
    }
}
```

Add `contentType = { "item" }` alongside `key` so the lazy layout can reuse slots, and hoist per-item animation state (`rememberSwipeToDismissBoxState()`, transition state) inside the item lambda so it is keyed with the item.

`remember { spring(...) }` avoids re-allocating the spec on every recomposition. The allocation is small, so this matters mainly in lazy item content; motion-scheme tokens (`motion.defaultSpatialSpec()`) are already cheap to call.

### Avoiding Recomposition in Animations

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun AvoidRecompositionInAnimations() {
    val motion = MaterialTheme.motionScheme

    // ✅ CORRECT: Use graphicsLayer for visual-only transforms
    // graphicsLayer does NOT trigger recomposition
    var pressed by remember { mutableStateOf(false) }

    val scale by animateFloatAsState(
        targetValue = if (pressed) 0.95f else 1f,
        animationSpec = motion.fastEffectsSpec(),
        label = "pressScale"
    )

    Card(
        modifier = Modifier
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .pointerInput(Unit) {
                detectTapGestures(
                    onPress = {
                        pressed = true
                        tryAwaitRelease()
                        pressed = false
                    }
                )
            }
    ) {
        Text("Press me", modifier = Modifier.padding(24.dp))
    }

    // ❌ WORSE: Modifier.scale(scale) is graphicsLayer under the hood, so it does
    // not relayout — but reading `scale` here happens during COMPOSITION, so this
    // composable recomposes on every animation frame. The lambda form above defers
    // the read to the draw phase. Same distinction for Modifier.offset(x, y) vs
    // Modifier.offset { IntOffset(...) }, and .alpha(a) vs graphicsLayer { alpha = a }.
    Card(
        modifier = Modifier.scale(scale)
    ) {
        Text("Expensive", modifier = Modifier.padding(24.dp))
    }
}
```

### Deferred Reading of Animation Values

```kotlin
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun DeferredAnimationReading() {
    val motion = MaterialTheme.motionScheme
    var targetAlpha by remember { mutableFloatStateOf(1f) }

    val alpha by animateFloatAsState(
        targetValue = targetAlpha,
        animationSpec = motion.fastEffectsSpec(),
        label = "alpha"
    )

    // ✅ CORRECT: Read animation value inside drawBehind (draw phase only)
    Box(
        modifier = Modifier
            .size(100.dp)
            .drawBehind {
                drawRect(Color.Blue.copy(alpha = alpha))
            }
    )

    // ❌ WRONG: Reading in composition phase triggers recomposition per frame
    Box(
        modifier = Modifier
            .size(100.dp)
            .background(Color.Blue.copy(alpha = alpha))  // Recomposes every frame!
    )
}
```

---

## 9. Common Mistakes

| # | Mistake | Fix |
|---|---------|-----|
| 1 | Wrong opt-in annotation | On 1.5.0-alpha26 only the loading indicators and `MaterialShapes` / `Morph.toPath` / `RoundedPolygon.toShape` need `ExperimentalMaterial3ExpressiveApi`; `AppBarWithSearch` needs `ExperimentalMaterial3Api`. Opting into the wrong one still fails to compile. |
| 2 | Using `MaterialTheme` instead of `MaterialExpressiveTheme` | Replace with `MaterialExpressiveTheme` to get expressive defaults for motion, shapes, and typography. |
| 3 | Using duration-based `tween()` for all animations | Use spring-based specs from `MaterialTheme.motionScheme` for physics-based motion. Reserve `tween()` for color and opacity only. |
| 4 | Creating spring specs inline in composable body | Wrap with `remember { spring(...) }` or use motion scheme tokens to avoid allocation per recomposition. |
| 5 | Ignoring reduced motion accessibility setting | There is no `LocalReduceMotion` in Compose for Android. Read `Settings.Global.ANIMATOR_DURATION_SCALE == 0f`, expose it via your own composition local, and fall back to `snap()`. |
| 6 | Reading an animated `State` in composition (`Modifier.scale(v)`, `Modifier.offset(x, y)`, `.alpha(v)`) | Use the lambda forms — `graphicsLayer { scaleX = v }`, `offset { IntOffset(...) }` — so the read happens in the layout/draw phase instead of recomposing every frame. |
| 7 | Mixing unpaired color roles (e.g., `primaryContainer` background with `onTertiaryContainer` text) | Always use paired color roles (`primaryContainer` + `onPrimaryContainer`) to guarantee contrast ratios. |
| 8 | Calling `expressiveDarkColorScheme()` | It does not exist. Use `expressiveLightColorScheme()` for light and the standard `darkColorScheme()` for dark. |
| 9 | Forgetting stable keys in animated `LazyColumn` items | Always provide `key = { item.id }` so animations are preserved when items reorder or update. |
| 10 | Not providing `contentDescription` for animated icons that change state | Add `semantics { stateDescription = ... }` or explicit `contentDescription` to toggle buttons and animated icons. |
| 11 | Using emphasized typography everywhere | Reserve `*Emphasized` styles for actual emphasis moments (hero titles, section headers, CTAs). Overuse defeats purpose. |
| 12 | Setting `dampingRatio` to 0 (undamped spring) | Infinite oscillation. The bounciest preset is `DampingRatioHighBouncy` = `0.2f`; note `DampingRatioLowBouncy` is `0.75f` (least bouncy of the bouncy set), not 0.2f. |
| 13 | Applying shape morphing to components that clip children | Shape morphing during clip can cause visual artifacts. Use `graphicsLayer { clip = true; shape = ... }` for animated clipping. |
| 14 | Not testing on API < 31 when using dynamic color | Dynamic color requires Android 12+. Fall back to `expressiveLightColorScheme()` / `darkColorScheme()`. Note that choosing `dynamic*ColorScheme` at all opts out of the expressive baseline palette. |
| 15 | Assuming any of this is on the stable BOM | Nothing here except `WideNavigationRail` / `ShortNavigationBar` is public in material3 1.4.0 — even `MaterialExpressiveTheme` and the `*Emphasized` styles are `internal`. Use `compose-bom-alpha`. |
| 16 | Reusing the AOSP `scale(w/2, h/2) + translate(1,1)` morph matrix with `MaterialShapes` | Those polygons are `normalized()` to 0..1, not -1..1. Scale by the full `size.width`/`size.height` with no translate. |

---

## Quick Reference: Component Selection Guide

Everything below requires material3 `1.5.0-alpha*` — including the flexible app bars and `VerticalSlider`, which are `internal` in 1.4.0.

| Need | Component |
|------|-----------|
| Group related actions | `ButtonGroup` |
| Playful loading state | `CircularWavyProgressIndicator`, `LinearWavyProgressIndicator` |
| Inline loading | `ContainedLoadingIndicator`, `LoadingIndicator` |
| Organized dropdown | `DropdownMenuGroup`, `DropdownMenuPopup` |
| Toggle with emphasis | `ToggleButton`, `FilledTonalToggleButton`, `OutlinedToggleButton`, `ElevatedToggleButton` |
| Expandable search | `ExpandedDockedSearchBarWithGap` |
| Flexible app bars | `FlexibleBottomAppBar`, `MediumFlexibleTopAppBar`, `LargeFlexibleTopAppBar`, `TwoRowsTopAppBar` |
| Expandable FAB | `FloatingActionButtonMenu` + `FloatingActionButtonMenuItem` |
| Floating toolbars | `HorizontalFloatingToolbar`, `VerticalFloatingToolbar` |
| Sized FABs | `MediumFloatingActionButton`, `SmallExtendedFloatingActionButton`, `MediumExtendedFloatingActionButton`, `LargeExtendedFloatingActionButton` |
| Toggle FAB | `ToggleFloatingActionButton` |
| Split actions | `SplitButtonLayout` |
| Vertical input | `VerticalSlider` |
