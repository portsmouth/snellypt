precision highp float;

// Samplers
uniform sampler2D Radiance;         // 0 (IO buffer)
uniform sampler2D RngData;          // 1 (IO buffer)
uniform sampler2D WavelengthToXYZ;  // 2
uniform sampler2D ICDF;             // 3
uniform sampler2D iorTex;           // 4
uniform sampler2D kTex;             // 5 (for metals)
uniform sampler2D envMap;           // 6
in vec2 vTexCoord;

layout(location = 0) out vec4 gbuf_rad;
layout(location = 1) out vec4 gbuf_rng;

// Camera parameters
uniform vec2 resolution;
uniform vec3 camPos;
uniform vec3 camDir;
uniform vec3 camX;
uniform vec3 camY;
uniform float camFovy; // degrees
uniform float camAspect;
uniform float camAperture;
uniform float camFocalDistance;

// Pathtracing parameters
uniform float filterRadius;
uniform float radianceClamp;
uniform float skipProbability;
uniform bool maxStepsIsMiss;

// Length scales
uniform float lengthScale;
uniform float minLengthScale;
uniform float maxLengthScale;

// Sky parameters
uniform bool haveEnvMap;
uniform bool envMapVisible;
uniform float envMapPhiRotation;
uniform float envMapThetaRotation;
uniform float envMapTransitionAngle;
uniform float skyPower;
uniform vec3 skyTintUp;
uniform vec3 skyTintDown;

// Sun parameters
uniform float sunPower;
uniform float sunAngularSize;
uniform float sunLatitude;
uniform float sunLongitude;
uniform vec3 sunColor;
uniform vec3 sunDir;
uniform bool sunVisibleDirectly;

// Surface material parameters
uniform vec3 surfaceDiffuseAlbedoRGB;
uniform vec3 surfaceSpecAlbedoRGB;
uniform float surfaceRoughness;
uniform float surfaceIor;
uniform float subsurface;
uniform vec3 subsurfaceAlbedoRGB;
uniform float subsurfaceMFP;
uniform float subsurfaceAnisotropy;
uniform float subsurfaceDiffuseWeight;
uniform int maxSSSSteps;

// Volumetric emission constants
uniform float volumeEmission;
uniform vec3 volumeEmissionColorRGB;

// Fog
uniform bool fogEnable;
uniform float fogMaxOpticalDepth;
uniform float fogMFP;
uniform vec3 fogEmission;
uniform vec3 fogTint;


//////////////////////////////////////////////////////////////
// Defines
//////////////////////////////////////////////////////////////
#define DENOM_TOLERANCE 1.0e-7
#define PDF_EPSILON 1.0e-6
#define THROUGHPUT_EPSILON 1.0e-5
#define RADIANCE_EPSILON 1.0e-6
#define M_PI 3.141592653589793

#define MAT_INVAL  -1
#define MAT_DIELE  0
#define MAT_METAL  1
#define MAT_SURFA  2

/// GLSL floating point pseudorandom number generator, from
/// "Implementing a Photorealistic Rendering System using GLSL", Toshiya Hachisuka
/// http://arxiv.org/pdf/1505.06022.pdf
float rand(inout vec4 rnd)
{
    const vec4 q = vec4(   1225.0,    1585.0,    2457.0,    2098.0);
    const vec4 r = vec4(   1112.0,     367.0,      92.0,     265.0);
    const vec4 a = vec4(   3423.0,    2646.0,    1707.0,    1999.0);
    const vec4 m = vec4(4194287.0, 4194277.0, 4194191.0, 4194167.0);
    vec4 beta = floor(rnd/q);
    vec4 p = a*(rnd - beta*q) - beta*r;
    beta = (1.0 - sign(p))*0.5*m;
    rnd = p + beta;
    return fract(dot(rnd/m, vec4(1.0, -1.0, 1.0, -1.0)));
}

//////////////////////////////////////////////////////////////
// Dynamically injected code
//////////////////////////////////////////////////////////////

__DEFINES__

__SHADER__

__IOR_FUNC__


/////////////////////////////////////////////////////////////////////////
// Basis transforms
/////////////////////////////////////////////////////////////////////////

vec3 safe_normalize(vec3 N)
{
    float l = length(N);
    return N/max(l, DENOM_TOLERANCE);
}

float cosTheta2(in vec3 nLocal) { return nLocal.z*nLocal.z; }
float cosTheta(in vec3 nLocal)  { return nLocal.z; }
float sinTheta2(in vec3 nLocal) { return 1.0 - cosTheta2(nLocal); }
float sinTheta(in vec3 nLocal)  { return sqrt(max(0.0, sinTheta2(nLocal))); }
float tanTheta2(in vec3 nLocal) { float ct2 = cosTheta2(nLocal); return max(0.0, 1.0 - ct2) / max(ct2, 1.0e-7); }
float tanTheta(in vec3 nLocal)  { return sqrt(max(0.0, tanTheta2(nLocal))); }

struct Basis
{
    // right-handed coordinate system
    vec3 nW; // aligned with the z-axis in local space
    vec3 tW; // aligned with the x-axis in local space
    vec3 bW; // aligned with the y-axis in local space
};

Basis sunBasis;

Basis makeBasis(in vec3 nW)
{
    Basis basis;
    basis.nW = nW;
    if (abs(nW.z) < abs(nW.x))
    {
        basis.tW.x =  nW.z;
        basis.tW.y =  0.0;
        basis.tW.z = -nW.x;
    }
    else
    {
        basis.tW.x =  0.0;
        basis.tW.y = nW.z;
        basis.tW.z = -nW.y;
    }
    basis.tW = safe_normalize(basis.tW);
    basis.bW = cross(nW, basis.tW);
    return basis;
}

vec3 worldToLocal(in vec3 vWorld, in Basis basis)
{
    return vec3( dot(vWorld, basis.tW),
                 dot(vWorld, basis.bW),
                 dot(vWorld, basis.nW) );
}

vec3 localToWorld(in vec3 vLocal, in Basis basis)
{
    return basis.tW*vLocal.x + basis.bW*vLocal.y + basis.nW*vLocal.z;
}

vec3 rgbToXyz(in vec3 RGB)
{
    // (Assuming RGB in sRGB color space)
    vec3 XYZ;
    XYZ.x = 0.4124564*RGB.r + 0.3575761*RGB.g + 0.1804375*RGB.b;
    XYZ.y = 0.2126729*RGB.r + 0.7151522*RGB.g + 0.0721750*RGB.b;
    XYZ.z = 0.0193339*RGB.r + 0.1191920*RGB.g + 0.9503041*RGB.b;
    return XYZ;
}

float maxComponent(in vec3 v)
{
    return max(max(v.r, v.g), v.b);
}

float maxComponent(float f)
{
    return f;
}

float averageComponent(in vec3 v)
{
    return (v.r + v.g + v.b)/3.0;
}

float averageComponent(float f)
{
    return f;
}


/////////////////////////////////////////////////////////////////////////
// Sampling formulae
/////////////////////////////////////////////////////////////////////////

/// Uniformly sample a sphere
vec3 sampleSphereUniformly(inout vec4 rnd)
{
    float z = 1.0 - 2.0*rand(rnd);
    float r = sqrt(max(0.0, 1.0 - z*z));
    float phi = 2.0*M_PI*rand(rnd);
    float x = cos(phi);
    float y = sin(phi);
    // pdf = 1.0/(4.0*M_PI);
    return vec3(x, y, z);
}

vec3 sampleHemisphereUniformly(inout vec4 rnd)
{
    float xi = rand(rnd);
    float r = sqrt(1.0 - xi*xi);
    float phi = 2.0 * M_PI * rand(rnd);
    float x = r * cos(phi);
    float y = r * sin(phi);
    float z = xi;
    // pdf = 1.0/(2.0*M_PI);
    return vec3(x, y, z);
}

// Do cosine-weighted sampling of hemisphere
vec3 sampleHemisphereCosineWeighted(inout vec4 rnd, inout float pdf)
{
    float r = sqrt(rand(rnd));
    float theta = 2.0 * M_PI * rand(rnd);
    float x = r * cos(theta);
    float y = r * sin(theta);
    float z = sqrt(max(0.0, 1.0 - x*x - y*y));
    pdf = abs(z) / M_PI;
    return vec3(x, y, z);
}

// pdf for cosine-weighted sampling of hemisphere
float pdfHemisphereCosineWeighted(in vec3 wiL)
{
    if (wiL.z < 0.0) return 0.0;
    return wiL.z / M_PI;
}

float powerHeuristic(const float a, const float b)
{
    return a/(a + b);
}


/////////////////////////////////////////////////////////////////////////
// Phase function
/////////////////////////////////////////////////////////////////////////

float phaseFunction(float mu, float anisotropy)
{
    float g = anisotropy;
    float gSqr = g*g;
    return (1.0/(4.0*M_PI)) * (1.0 - gSqr) / pow(1.0 - 2.0*g*mu + gSqr, 1.5);
}

vec3 samplePhaseFunction(in vec3 rayDir, float anisotropy, inout vec4 rnd)
{
    float g = anisotropy;
    float costheta;
    if (abs(g)<1.0e-3)
        costheta = 1.0 - 2.0*rand(rnd);
    else
        costheta = 1.0/(2.0*g) * (1.0 + g*g - ((1.0-g*g)*(1.0-g+2.0*g*rand(rnd))));
    float sintheta = sqrt(max(0.0, 1.0-costheta*costheta));
    float phi = 2.0*M_PI*rand(rnd);
    Basis basis = makeBasis(rayDir);
    return costheta*rayDir + sintheta*(cos(phi)*basis.tW + sin(phi)*basis.bW);
}

/////////////////////////////////////////////////////////////////////////
// Beckmann Microfacet formulae
/////////////////////////////////////////////////////////////////////////

// m = the microfacet normal (in the local space where z = the macrosurface normal)
float microfacetEval(in vec3 m, in float roughness)
{
    float t2 = tanTheta2(m);
    float c2 = cosTheta2(m);
    float roughnessSqr = roughness*roughness;
    float epsilon = 1.0e-9;
    float exponent = t2 / max(roughnessSqr, epsilon);
    float D = exp(-exponent) / max(M_PI*roughnessSqr*c2*c2, epsilon);
    return D;
}

// m = the microfacet normal (in the local space where z = the macrosurface normal)
vec3 microfacetSample(inout vec4 rnd, in float roughness)
{
    float phiM = (2.0 * M_PI) * rand(rnd);
    float cosPhiM = cos(phiM);
    float sinPhiM = sin(phiM);
    float epsilon = 1.0e-9;
    float tanThetaMSqr = -roughness*roughness * log(max(epsilon, rand(rnd)));
    float cosThetaM = 1.0 / sqrt(1.0 + tanThetaMSqr);
    float sinThetaM = sqrt(max(0.0, 1.0 - cosThetaM*cosThetaM));
    return safe_normalize(vec3(sinThetaM*cosPhiM, sinThetaM*sinPhiM, cosThetaM));
}

float microfacetPDF(in vec3 m, in float roughness)
{
    return microfacetEval(m, roughness) * abs(cosTheta(m));
}

// Shadow-masking function
// Approximation from Walter et al (v = arbitrary direction, m = microfacet normal)
float smithG1(in vec3 vLocal, in vec3 mLocal, float roughness)
{
    float tanThetaAbs = abs(tanTheta(vLocal));
    float epsilon = 1.0e-6;
    if (tanThetaAbs < epsilon) return 1.0; // perpendicular incidence -- no shadowing/masking
    if (dot(vLocal, mLocal) * vLocal.z <= 0.0) return 0.0; // Back side is not visible from the front side, and the reverse.
    float a = 1.0 / (max(roughness, epsilon) * tanThetaAbs); // Rational approximation to the shadowing/masking function (Walter et al)  (<0.35% rel. error)
    if (a >= 1.6) return 1.0;
    float aSqr = a*a;
    return (3.535*a + 2.181*aSqr) / (1.0 + 2.276*a + 2.577*aSqr);
}

float smithG2(in vec3 woL, in vec3 wiL, in vec3 mLocal, float roughness)
{
    return smithG1(woL, mLocal, roughness) * smithG1(wiL, mLocal, roughness);
}

/////////////////////////////////////////////////////////////////////////
// BRDF functions
/////////////////////////////////////////////////////////////////////////

#ifdef HAS_GEOMETRY

// ****************************        Surface        ****************************

#ifdef HAS_SURFACE

// cosi         = magnitude of the cosine of the incident ray angle to the normal
// eta_ti       = ratio et/ei of the transmitted IOR (et) and incident IOR (ei)
float fresnelDielectricReflectance(in float cosi, in float eta_ti)
{
    float c = cosi;
    float g = eta_ti*eta_ti - 1.0 + c*c;
    if (g > 0.0)
    {
        g = sqrt(g);
        float A = (g-c) / (g+c);
        float B = (c*(g+c) - 1.0) / (c*(g-c) + 1.0);
        return 0.5*A*A*(1.0 + B*B);
    }
    return 1.0; // total internal reflection
}

vec3 SURFACE_DIFFUSE_REFL_EVAL(in vec3 X, in vec3 nW, in vec3 winputW, in vec3 rgb)
{
    vec3 reflRGB = SURFACE_DIFFUSE_REFLECTANCE(surfaceDiffuseAlbedoRGB, X, nW, winputW);
    return reflRGB;
}

vec3 SUBSURFACE_ALBEDO_EVAL(in vec3 X, in vec3 nW, in vec3 rgb)
{
    vec3 reflRGB = SUBSURFACE_ALBEDO(subsurfaceAlbedoRGB, X, nW);
    return reflRGB;
}

vec3 SURFACE_SPEC_REFL_EVAL(in vec3 X, in vec3 nW, in vec3 winputW, in vec3 rgb)
{
    vec3 reflRGB = SURFACE_SPECULAR_REFLECTANCE(surfaceSpecAlbedoRGB, X, nW, winputW);
    return reflRGB;
}

vec3 evaluateSurface(in vec3 X, in Basis basis, in vec3 winputL, in vec3 woutputL, in float wavelength_nm, in vec3 rgb)
{
    if (winputL.z<0.0) return vec3(0.0);
    vec3 winputW = localToWorld(winputL, basis);
    vec3 diffuseAlbedo = (1.0 - subsurface)*SURFACE_DIFFUSE_REFL_EVAL(X, basis.nW, winputW, rgb);
    vec3    specAlbedo = SURFACE_SPEC_REFL_EVAL(X, basis.nW, winputW, rgb);
    float ior = surfaceIor;
    float roughness = SURFACE_ROUGHNESS(surfaceRoughness, X, basis.nW);
    float Fr = fresnelDielectricReflectance(woutputL.z, ior);
    vec3 h = normalize(woutputL + winputL); // Compute the reflection half-vector
    float D = microfacetEval(h, roughness);
    float G = smithG2(winputL, woutputL, h, roughness);
    vec3 f = Fr * specAlbedo * D * G / max(4.0*abs(cosTheta(woutputL))*abs(cosTheta(winputL)), DENOM_TOLERANCE);
    float E = fresnelDielectricReflectance(winputL.z, ior);
    f += (1.0 - E) * diffuseAlbedo/M_PI;
    return f;
}

float pdfSurface(in vec3 X, in Basis basis, in vec3 winputL, in vec3 woutputL, in float wavelength_nm, in vec3 rgb)
{
    if (winputL.z<0.0) return PDF_EPSILON;
    vec3 winputW = localToWorld(winputL, basis);
    vec3 diffuseAlbedo = (1.0 - subsurface)*SURFACE_DIFFUSE_REFL_EVAL(X, basis.nW, winputW, rgb);
    vec3    specAlbedo = SURFACE_SPEC_REFL_EVAL(X, basis.nW, winputW, rgb);
    float ior = surfaceIor;
    float E = fresnelDielectricReflectance(abs(winputL.z), ior);
    float specWeight    = (E      )*averageComponent(specAlbedo);
    float diffuseWeight = (1.0 - E)*averageComponent(diffuseAlbedo);
    float weightSum = max(specWeight + diffuseWeight, DENOM_TOLERANCE);
    float specProb = specWeight/weightSum;
    float roughness = SURFACE_ROUGHNESS(surfaceRoughness, X, basis.nW);
    float diffusePdf = pdfHemisphereCosineWeighted(woutputL);
    vec3 h = safe_normalize(woutputL + winputL); // reflection half-vector
    float dwh_dwo = 1.0 / max(abs(4.0*dot(winputL, h)), DENOM_TOLERANCE); // Jacobian of the half-direction mapping
    float specularPdf = microfacetPDF(h, roughness) * dwh_dwo;
    return specProb*specularPdf + (1.0-specProb)*diffusePdf;
}

vec3 sampleSurface(in vec3 X, in Basis basis, in vec3 winputL, in float wavelength_nm, in vec3 rgb,
                           inout vec3 woutputL, inout float pdfOut, inout vec4 rnd)
{
    if (winputL.z<0.0) return vec3(0.0);
    vec3 winputW = localToWorld(winputL, basis);
    vec3 diffuseAlbedo = (1.0 - subsurface)*SURFACE_DIFFUSE_REFL_EVAL(X, basis.nW, winputW, rgb);
    vec3    specAlbedo = SURFACE_SPEC_REFL_EVAL(X, basis.nW, winputW, rgb);
    float ior = surfaceIor;
    float roughness = SURFACE_ROUGHNESS(surfaceRoughness, X, basis.nW);
    float E = fresnelDielectricReflectance(abs(winputL.z), ior);
    float specWeight    = (E      )*averageComponent(specAlbedo);
    float diffuseWeight = (1.0 - E)*averageComponent(diffuseAlbedo);
    float weightSum = max(specWeight + diffuseWeight, DENOM_TOLERANCE);
    float specProb = specWeight/weightSum;
    if (rand(rnd) >= specProb) // diffuse term, happens with probability 1-specProb
    {
        woutputL = sampleHemisphereCosineWeighted(rnd, pdfOut);
        pdfOut *= (1.0-specProb);
        return (1.0 - E) * diffuseAlbedo/M_PI;
    }
    else
    {
        vec3 m = microfacetSample(rnd, roughness); // Sample microfacet normal m
        woutputL = -winputL + 2.0*dot(winputL, m)*m; // Compute woutputL by reflecting winputL about m
        pdfOut = specProb;
        if (woutputL.z<DENOM_TOLERANCE) return vec3(0.0);
        float D = microfacetEval(m, roughness);
        float G = smithG2(winputL, woutputL, m, roughness); // Shadow-masking function
        float Fr = fresnelDielectricReflectance(abs(winputL.z), ior);
        vec3 f = Fr * specAlbedo * D * G / max(4.0*abs(cosTheta(woutputL))*abs(cosTheta(winputL)), DENOM_TOLERANCE);
        float dwh_dwo; // Jacobian of the half-direction mapping
        dwh_dwo = 1.0 / max(abs(4.0*dot(winputL, m)), DENOM_TOLERANCE);
        pdfOut *= microfacetPDF(m, roughness) * dwh_dwo;
        return f;
    }
}

#endif

// ****************************        BSDF common interface        ****************************

vec3 evaluateBsdf( in vec3 X, in Basis basis, in vec3 winputL, in vec3 woutputL, in int material, in float wavelength_nm, in vec3 rgb, bool fromCamera,
                           inout vec4 rnd )
{
#ifdef HAS_SURFACE
    if (material==MAT_SURFA) { return    evaluateSurface(X, basis, winputL, woutputL, wavelength_nm, rgb); }
#endif
}

vec3 sampleBsdf( in vec3 X, in Basis basis, in vec3 winputL, in int material, in float wavelength_nm, in vec3 rgb, bool fromCamera,
                         inout vec3 woutputL, inout float pdfOut, inout vec4 rnd )
{
#ifdef HAS_SURFACE
    if (material==MAT_SURFA) { return    sampleSurface(X, basis, winputL, wavelength_nm, rgb, woutputL, pdfOut, rnd); }
#endif
}

float pdfBsdf( in vec3 X, in Basis basis, in vec3 winputL, in vec3 woutputL, in int material, in float wavelength_nm, in vec3 rgb, bool fromCamera )
{
#ifdef HAS_SURFACE
    if (material==MAT_SURFA) { return    pdfSurface(X, basis, winputL, woutputL, wavelength_nm, rgb); }
#endif
}

#endif // HAS_GEOMETRY


#ifdef HAS_VOLUME_EMISSION

vec3 VOLUME_EMISSION_EVAL(in vec3 X, in vec3 rgb)
{
    vec3 emission = VOLUME_EMISSION(volumeEmissionColorRGB * volumeEmission, X);
    return emission;
}

#endif // HAS_VOLUME_EMISSION

///////////////////////////////////////////////////////////////////////////////////
// SDF raymarcher
///////////////////////////////////////////////////////////////////////////////////

// find first hit along specified ray
bool traceRay(in vec3 start, in vec3 dir,
              inout vec3 hit, inout int material, float maxMarchDist)
{
    material = MAT_INVAL;
    float minMarch = minLengthScale;
    const float HUGE_VAL = 1.0e20;
    float sdf = HUGE_VAL;
#ifdef HAS_SURFACE
    float sdf_surfa = abs(SDF_SURFACE(start));    sdf = min(sdf, sdf_surfa);
#endif
    float InitialSign = sign(sdf);
    float t = InitialSign * sdf; // (always take the first step along the ray direction)
    if (abs(t)>=maxMarchDist) return false;
    for (int n=0; n<__MAX_MARCH_STEPS__; n++)
    {
        vec3 pW = start + t*dir;
        sdf = HUGE_VAL;
#ifdef HAS_SURFACE
        sdf_surfa = abs(SDF_SURFACE(pW));    if (sdf_surfa<minMarch) { material = MAT_SURFA; hit = start + t*dir; return true; } sdf = min(sdf, sdf_surfa);
#endif
        // With this formula, the ray advances whether sdf is initially negative or positive --
        // but on crossing the zero isosurface, sdf flips allowing bracketing of the root.
        t += InitialSign * sdf;
        if (abs(t)>=maxMarchDist) return false;
    }
    return !maxStepsIsMiss;
}

vec3 normal(in vec3 pW, int material)
{
    // Compute normal as gradient of SDF
    float normalEpsilon = 2.0*minLengthScale;
    vec3 e = vec3(normalEpsilon, 0.0, 0.0);
    vec3 Xp = pW+e.xyy; vec3 Xn = pW-e.xyy;
    vec3 Yp = pW+e.yxy; vec3 Yn = pW-e.yxy;
    vec3 Zp = pW+e.yyx; vec3 Zn = pW-e.yyx;
    vec3 N;
#ifdef HAS_SURFACE
    if (material==MAT_SURFA) { N = vec3(   SDF_SURFACE(Xp) -    SDF_SURFACE(Xn),    SDF_SURFACE(Yp) -    SDF_SURFACE(Yn),    SDF_SURFACE(Zp) -    SDF_SURFACE(Zn)); return safe_normalize(N); }
#endif
}

#ifdef HAS_NORMALMAP
vec3 perturbNormal(in vec3 X, in Basis basis, int material)
{
#ifdef HAS_SURFACE_NORMALMAP
    if (material==MAT_SURFA)
    {
        vec3 nL_perturbed = SURFACE_NORMAL_MAP(X, basis.nW);
        return localToWorld(normalize(nL_perturbed), basis);
    }
#endif
    return basis.nW;
}
#endif


//////////////////////////////////
// fog transmittance
//////////////////////////////////

// Return the amount of light transmitted (per-channel) along a known "free" segment (i.e. free of geometry)
vec3 transmittanceOverFreeSegment(in vec3 pW, in vec3 rayDir, float segmentLength)
{
    vec3 Tr = vec3(1.0);
#ifdef HAS_FOG
    if (fogEnable)
    {
        vec3 fogAbsorption = vec3(1.0) - fogTint;
        vec3 opticalDepthFog = fogMaxOpticalDepth * (vec3(1.0) - exp(-segmentLength*fogAbsorption/fogMFP));
        Tr *= exp(-opticalDepthFog);
    }
#endif
    return Tr;
}

vec3 transmittanceOverSegment(in vec3 pW, in vec3 rayDir, float segmentLength)
{
    vec3 pW_surface;
    int hitMaterial;
    bool hit = traceRay(pW, rayDir, pW_surface, hitMaterial, segmentLength);
    if (hit)
        return vec3(0.0);
    else
#ifdef HAS_FOG
        return transmittanceOverFreeSegment(pW, rayDir, segmentLength);
#else
        return vec3(1.0);
#endif
}

vec3 atmosphericInscatteringRadiance(in vec3 Tr)
{
    if (!fogEnable)
        return vec3(0.0);
    return (1.0 - Tr) * fogEmission;
}



////////////////////////////////////////////////////////////////////////////////
// Light sampling
////////////////////////////////////////////////////////////////////////////////

//////////////////////////////////////////////
// Sky
//////////////////////////////////////////////

vec3 environmentRadianceRGB(in vec3 dirW)
{
    float rot_phi   = M_PI*envMapPhiRotation/180.0;
    float rot_theta = M_PI*envMapThetaRotation/180.0;
    vec3 sky_pole = vec3(sin(rot_theta), cos(rot_theta), 0.0);
    Basis sky_basis = makeBasis(sky_pole);
    vec3 dirL = worldToLocal(dirW, sky_basis);
    float phi = atan(dirL.y, dirL.x) + M_PI + rot_phi;
    phi -= 2.0*M_PI*floor(phi/(2.0*M_PI)); // wrap phi to [0, 2*pi]
    float theta = acos(dirL.z);
    float u = phi/(2.0*M_PI);
    float v = theta/M_PI;
    vec3 RGB = vec3(1.0);
    if (haveEnvMap)
        RGB = texture(envMap, vec2(u,v)).rgb;
    float t = dot(dirW, sky_pole);
    float tt = envMapTransitionAngle/180.0;
    RGB *= skyPower * mix(skyTintDown, skyTintUp, smoothstep(-tt, tt, t));
    return RGB;
}

vec3 environmentRadiance(in vec3 dir, in vec3 rgb)
{
    vec3 RGB_sky = environmentRadianceRGB(dir);
    return RGB_sky;
}

float skyPowerEstimate()
{
    return 2.0*M_PI * skyPower * 0.5*(maxComponent(skyTintUp) + maxComponent(skyTintDown));
}

vec3 sampleSkyAtSurface(Basis basis, in vec3 rgb, inout vec4 rnd,
                                inout vec3 woutputL, inout vec3 woutputW, inout float pdfDir)
{
    if (skyPower<RADIANCE_EPSILON)
        return vec3(0.0);
    woutputL = sampleHemisphereCosineWeighted(rnd, pdfDir);
    woutputW = localToWorld(woutputL, basis);
    return environmentRadiance(woutputW, rgb);
}


//////////////////////////////////////////////
// Sun
//////////////////////////////////////////////

vec3 sampleSunDir(inout vec4 rnd, inout float pdfDir)
{
    float theta_max = sunAngularSize * M_PI/180.0;
    float theta = theta_max * sqrt(rand(rnd));
    float costheta = cos(theta);
    float sintheta = sqrt(max(0.0, 1.0-costheta*costheta));
    float phi = 2.0 * M_PI * rand(rnd);
    float cosphi = cos(phi);
    float sinphi = sin(phi);
    float x = sintheta * cosphi;
    float y = sintheta * sinphi;
    float z = costheta;
    float solid_angle = 2.0*M_PI*(1.0 - cos(theta_max));
    pdfDir = 1.0/solid_angle;
    return localToWorld(vec3(x, y, z), sunBasis);
}

float pdfSun(in vec3 dir)
{
    float theta_max = sunAngularSize * M_PI/180.0;
    if (dot(dir, sunDir) < cos(theta_max)) return 0.0;
    float solid_angle = 2.0*M_PI*(1.0 - cos(theta_max));
    return 1.0/solid_angle;
}

vec3 sunRadiance(in vec3 dir, in vec3 rgb)
{
    float theta_max = sunAngularSize * M_PI/180.0;
    if (dot(dir, sunDir) < cos(theta_max)) return vec3(0.0);
    vec3 RGB_sun = sunPower * sunColor;
    return RGB_sun;
}

vec3 sampleSunAtSurface(Basis basis, in vec3 rgb, inout vec4 rnd,
                                inout vec3 woutputL, inout vec3 woutputW, inout float pdfDir)
{
    if (sunPower<RADIANCE_EPSILON)
        return vec3(0.0);
    woutputW = sampleSunDir(rnd, pdfDir);
    woutputL = worldToLocal(woutputW, basis);
    if (woutputL.z < 0.0) return vec3(0.0);
    return sunRadiance(woutputW, rgb);
}


//////////////////////////////////////////////
// Direct lighting routines
//////////////////////////////////////////////

// Estimate direct radiance at the given surface vertex
vec3 directSurfaceLighting(in vec3 pW, Basis basis, in vec3 winputW, in int material,
                                   float wavelength_nm, in vec3 rgb, inout vec4 rnd,
                                   inout float skyPdf, inout float sunPdf, inout float sphPdf)
{
    vec3 winputL = worldToLocal(winputW, basis);
    bool fromCamera = true; // camera path
    vec3 Ldirect = vec3(0.0);
    vec3 woutputL, woutputW;

    // Sky
    if (skyPower > RADIANCE_EPSILON)
    {
        vec3 Li = sampleSkyAtSurface(basis, rgb, rnd, woutputL, woutputW, skyPdf);
        if (averageComponent(Li) > RADIANCE_EPSILON)
        {
            Li *= transmittanceOverSegment(pW, woutputW, maxLengthScale);
            if (averageComponent(Li) > RADIANCE_EPSILON)
            {
                // Apply MIS weight with the BSDF pdf for the sampled direction
                float bsdfPdf = max(PDF_EPSILON, pdfBsdf(pW, basis, winputL, woutputL, material, wavelength_nm, rgb, fromCamera));
                vec3 f = evaluateBsdf(pW, basis, winputL, woutputL, material, wavelength_nm, rgb, fromCamera, rnd);
                float misWeight = powerHeuristic(skyPdf, bsdfPdf);
                Ldirect += f * Li/max(PDF_EPSILON, skyPdf) * abs(dot(woutputW, basis.nW)) * misWeight;
            }
        }
    }
    // Sun
    if (sunPower > RADIANCE_EPSILON)
    {
        vec3 Li = sampleSunAtSurface(basis, rgb, rnd, woutputL, woutputW, sunPdf);
        if (averageComponent(Li) > RADIANCE_EPSILON)
        {
            Li *= transmittanceOverSegment(pW, woutputW, maxLengthScale);
            if (averageComponent(Li) > RADIANCE_EPSILON)
            {
                // Apply MIS weight with the BSDF pdf for the sampled direction
                float bsdfPdf = max(PDF_EPSILON, pdfBsdf(pW, basis, winputL, woutputL, material, wavelength_nm, rgb, fromCamera));
                vec3 f = evaluateBsdf(pW, basis, winputL, woutputL, material, wavelength_nm, rgb, fromCamera, rnd);
                float misWeight = powerHeuristic(sunPdf, bsdfPdf);
                Ldirect += f * Li/max(PDF_EPSILON, sunPdf) * abs(dot(woutputW, basis.nW)) * misWeight;
            }
        }
    }
    return min(vec3(radianceClamp), Ldirect);
}


///////////////////////////////////////////////////////////////
// SSS
///////////////////////////////////////////////////////////////

#define HARDMAX_SSS_STEPS 256
#define MIN_SSS_STEPS_BEFORE_RR 4

#ifdef HAS_SURFACE
bool randomwalk_SSS(in vec3 pW, in Basis basis, inout vec4 rnd,
                    in float MFP, in vec3 subsurfaceAlbedo, in vec3 diffuseAlbedoEntry,
                    inout vec3 walk_throughput, inout vec3 pExit)
{
    // Returns true on successful walk to an exit point.
    // Otherwise false indicating termination without finding a valid exit point.
    vec3 pWalk = pW;
    vec3 dPw = 3.0*minLengthScale * basis.nW;
    pWalk -= dPw; // Displace walk into interior to avoid issues with trace numerics
    float pdfDir;
    vec3 dirwalkL = sampleHemisphereCosineWeighted(rnd, pdfDir);
    vec3 dirwalkW = -localToWorld(dirwalkL, basis); // (negative sign to start walk in interior hemisphere)

    // We assume a diffuse Lambertian lobe at the entry point
    // (either pure white, or with the diffuse albedo of the entry point, or somewhere in between)
    vec3 f = mix(vec3(1.0), diffuseAlbedoEntry, subsurfaceDiffuseWeight) / M_PI;
    vec3 fOverPdf = min(vec3(radianceClamp), f/max(PDF_EPSILON, pdfDir));
    vec3 surface_entry_throughput = fOverPdf * abs(dot(dirwalkW, basis.nW));
    walk_throughput = vec3(1.0); //surface_entry_throughput; // update walk throughput due to entry in medium
    for (int n=0; n<HARDMAX_SSS_STEPS; ++n)
    {
        if (n>maxSSSSteps)
            break;
        float walk_step = -log(rand(rnd)) * MFP * lengthScale;
        vec3 pHit;
        int hitMaterial;
        bool hit = traceRay(pWalk, dirwalkW, pHit, hitMaterial, walk_step);
        if (hit)
        {
            // walk left the surface
            pExit = pHit;
            return true;
        }
        // Point remains within the surface, continue walking.
        // First, make a Russian-roulette termination decision (after a minimum number of steps has been taken)
        float termination_prob = 0.0;
        if (n > MIN_SSS_STEPS_BEFORE_RR)
        {
            float continuation_prob = clamp(10.0*maxComponent(walk_throughput), 0.0, 1.0);
            float termination_prob = 1.0 - continuation_prob;
            if (rand(rnd) < termination_prob)
                break;
            walk_throughput /= continuation_prob; // update walk throughput due to RR continuation
        }
        dirwalkW = samplePhaseFunction(dirwalkW, subsurfaceAnisotropy, rnd);
        pWalk += walk_step*dirwalkW;
        walk_throughput *= subsurfaceAlbedo; // update walk throughput due to scattering in medium
    }
    return false;
}

// Estimate radiance at the SSS exit point
vec3 SSS_exit_radiance(in vec3 pW, Basis basis,
                               in vec3 rgb, inout vec4 rnd,
                               in vec3 diffuseAlbedoExit,
                               inout float skyPdf, inout float sunPdf, inout float sphPdf)
{
    vec3 dPw = 3.0*minLengthScale * basis.nW;
    vec3 Ldirect = vec3(0.0);
    vec3 woutputL, woutputW;

    // We assume a diffuse Lambertian lobe at the exit point
    // (either pure white, or with the diffuse albedo of the exit point, or somewhere in between)
    vec3 f = mix(vec3(1.0), diffuseAlbedoExit, subsurfaceDiffuseWeight) / M_PI;

    // Sky
    if (skyPower > RADIANCE_EPSILON)
    {
        vec3 Li = sampleSkyAtSurface(basis, rgb, rnd, woutputL, woutputW, skyPdf);
        Li *= transmittanceOverSegment(pW, woutputW, maxLengthScale);
        if (averageComponent(Li) > RADIANCE_EPSILON)
        {
            // Apply MIS weight with the BSDF pdf for the sampled direction
            float bsdfPdf = pdfHemisphereCosineWeighted(woutputL);
            float misWeight = powerHeuristic(skyPdf, bsdfPdf);
            Ldirect += f * Li/max(PDF_EPSILON, skyPdf) * abs(dot(woutputW, basis.nW)) * misWeight;
        }
    }
    // Sun
    if (sunPower > RADIANCE_EPSILON)
    {
        vec3 Li = sampleSunAtSurface(basis, rgb, rnd, woutputL, woutputW, sunPdf);
        Li *= transmittanceOverSegment(pW, woutputW, maxLengthScale);
        if (averageComponent(Li) > RADIANCE_EPSILON)
        {
            // Apply MIS weight with the BSDF pdf for the sampled direction
            float bsdfPdf = pdfHemisphereCosineWeighted(woutputL);
            float misWeight = powerHeuristic(sunPdf, bsdfPdf);
            Ldirect += f * Li/max(PDF_EPSILON, sunPdf) * abs(dot(woutputW, basis.nW)) * misWeight;
        }
    }
    return min(vec3(radianceClamp), Ldirect);
}

#endif


////////////////////////////////////////////////////////////////////////////////
// Pathtracing integrator
////////////////////////////////////////////////////////////////////////////////

void constructPrimaryRay(in vec2 pixel, inout vec4 rnd,
                         inout vec3 primaryStart, inout vec3 primaryDir)
{
    // Compute world ray direction for given (possibly jittered) fragment
    vec2 ndc = -1.0 + 2.0*(pixel/resolution.xy);
    float fh = tan(0.5*radians(camFovy)); // frustum height
    float fw = camAspect*fh;
    vec3 s = -fw*ndc.x*camX + fh*ndc.y*camY;
    primaryDir = safe_normalize(camDir + s);
    if (camAperture<=0.0)
    {
        primaryStart = camPos;
        return;
    }
    vec3 focalPlaneHit = camPos + camFocalDistance*primaryDir/dot(primaryDir, camDir);
    float lensRadial = camAperture * sqrt(rand(rnd));
    float theta = 2.0*M_PI*rand(rnd);
    vec3 lensPos = camPos + lensRadial*(-camX*cos(theta) + camY*sin(theta));
    primaryStart = lensPos;
    primaryDir = safe_normalize(focalPlaneHit - lensPos);
}


vec3 cameraPath(in vec3 primaryStart, in vec3 primaryDir, 
                        float wavelength_nm, in vec3 rgb, inout vec4 rnd)
{
    // Perform pathtrace starting from the camera lens to estimate the primary ray radiance, L
    vec3 L = vec3(0.0);
    float misWeightSky = 1.0; // For MIS book-keeping
    float misWeightSun = 1.0; // For MIS book-keeping
    vec3 pW = primaryStart;
    vec3 rayDir = primaryDir; // (opposite to light beam direction)

    vec3 throughput = vec3(1.0);
    for (int vertex=0; vertex<=__MAX_BOUNCES__; ++vertex)
    {
        // Bail out now if the path continuation throughput is below threshold
        if (maxComponent(throughput) < THROUGHPUT_EPSILON) break;

        // Raycast along current propagation direction rayDir, from current vertex pW to pW_next
        vec3 pW_next;
        int hitMaterial;
        bool hit = traceRay(pW, rayDir, pW_next, hitMaterial, maxLengthScale);
        float rayLength = maxLengthScale;

        vec3 Tr;
        if (hit)
        {
            rayLength = length(pW_next - pW);
            Tr = transmittanceOverFreeSegment(pW, rayDir, rayLength);
        }
        else
        {
            Tr = transmittanceOverFreeSegment(pW, rayDir, maxLengthScale);
#ifdef HAS_FOG
            if (averageComponent(Tr) > RADIANCE_EPSILON)
#endif
            {
                // This ray missed all geometry; add contribution from distant lights and terminate path
                if (!(vertex==0 && !envMapVisible)      && misWeightSky>0.0) L += throughput * Tr * misWeightSky * environmentRadiance(rayDir, rgb);
                if (!(vertex==0 && !sunVisibleDirectly) && misWeightSun>0.0) L += throughput * Tr * misWeightSun * sunRadiance(rayDir, rgb);
            }
#ifdef HAS_FOG
            // Add term for in-scattering in the homogeneous atmosphere (fog) over the segment to the light hit
            if (vertex<2) // (restrict to first two segments only, for efficiency)
                L += throughput * atmosphericInscatteringRadiance(Tr);
#endif
            // Ray escapes to infinity
            break;
        }

#ifdef HAS_FOG
        // Add term for in-scattering in the homogeneous atmosphere (fog) over the segment to the light hit
        if (vertex<2) // (restrict to first two segments only, for efficiency)
            L += throughput * atmosphericInscatteringRadiance(Tr);

        // Attenuate throughput to next hit due to atmospheric attenuation (Beer's law)
        throughput *= Tr;
#endif

        // This ray hit some geometry, so deal with the surface interaction.
        // First, compute the normal and thus the local vertex basis:
        pW = pW_next;
        vec3 nW = normal(pW, hitMaterial);
        vec3 ngW = nW; // geometric normal, needed for robust ray continuation
        Basis basis = makeBasis(nW);
#ifdef HAS_NORMALMAP
        nW = perturbNormal(pW, basis, hitMaterial);
        // If the incident ray lies below the hemisphere of the perturbed shading normal,
        // which can occur due to normal mapping, apply the "Flipping hack" to prevent artifacts
        // (see Schüßler, "Microfacet-based Normal Mapping for Robust Monte Carlo Path Tracing")
        if ((dot(nW, rayDir) > 0.0) && (hitMaterial != MAT_DIELE))
            nW = 2.0*ngW*dot(ngW, nW) - nW;
        basis = makeBasis(nW);
#endif

        // Make a binary choice whether to scatter at the surface, or do a subsurface random walk:
        bool do_subsurface_walk = false;
        float prob_sss = 0.0;
        vec3 subsurfaceAlbedo;
#ifdef HAS_SURFACE
        if (subsurfaceMFP > 0.0)         // a) the surface must have non-zero subsurface MFP, and
        {
            subsurfaceAlbedo = SUBSURFACE_ALBEDO_EVAL(pW, basis.nW, rgb);
            float diffuse_weight    = (1.0 - subsurface)*averageComponent(SURFACE_DIFFUSE_REFL_EVAL(pW, basis.nW, -rayDir, rgb));
            float    spec_weight    = averageComponent(SURFACE_SPEC_REFL_EVAL(pW, basis.nW, -rayDir, rgb));
            float subsurface_weight = subsurface * averageComponent(subsurfaceAlbedo) * 3.0; // weight more highly due to higher variance
            float total_weight = diffuse_weight + spec_weight + subsurface_weight;
            prob_sss = subsurface_weight / (total_weight + DENOM_TOLERANCE);
            prob_sss = clamp(prob_sss, 0.0, 1.0-PDF_EPSILON);
            do_subsurface_walk = (rand(rnd) < prob_sss);
        }
#endif

        // Regular surface bounce case
        if (!do_subsurface_walk)
        {
            // Sample BSDF for the next bounce direction
            vec3 winputW = -rayDir; // winputW, points *towards* the incident direction
            vec3 winputL = worldToLocal(winputW, basis);
            vec3 woutputL; // woutputL, points *towards* the outgoing direction
            bool fromCamera = true; // camera path
            float bsdfPdf;
            vec3 f = sampleBsdf(pW, basis, winputL, hitMaterial, wavelength_nm, rgb, fromCamera, woutputL, bsdfPdf, rnd);
            vec3 woutputW = localToWorld(woutputL, basis);

            // Detect dielectric transmission
#ifdef HAS_VOLUME_EMISSION
            // Add volumetric emission at the surface point, if present (treating it as an isotropic radiance field)
            L += throughput * VOLUME_EMISSION_EVAL(pW, rgb);
#endif

            // Update ray direction to the BSDF-sampled direction
            rayDir = woutputW;

            // Prepare for tracing the direct lighting and continuation rays
            pW += ngW * sign(dot(rayDir, ngW)) * 3.0*minLengthScale; // perturb vertex into half-space of scattered ray

            // Add direct lighting term at current surface vertex
            float skyPdf = 0.0;
            float sunPdf = 0.0;
            float sphPdf = 0.0;
            L += throughput * directSurfaceLighting(pW, basis, winputW, hitMaterial, wavelength_nm, rgb, rnd,
                                                    skyPdf, sunPdf, sphPdf);

            // Update path continuation throughput
            vec3 fOverPdf = min(vec3(radianceClamp), f/max(PDF_EPSILON, bsdfPdf));
            vec3 surface_throughput = fOverPdf * abs(dot(woutputW, nW)) / max(PDF_EPSILON, 1.0 - prob_sss);
            throughput *= surface_throughput;

            misWeightSky = powerHeuristic(bsdfPdf, skyPdf); // compute sky MIS weight for bounce ray
            misWeightSun = powerHeuristic(bsdfPdf, sunPdf); // compute sun MIS weight for bounce ray
        }

#ifdef HAS_SURFACE
        // Do subsurface random walk to a new vertex
        else
        {
            vec3 diffuseAlbedoEntry = SURFACE_DIFFUSE_REFL_EVAL(pW, basis.nW, -rayDir, rgb);
            vec3 walk_throughput;
            vec3 pExit;
            basis.nW = ngW; // (use basis with geometric normal for SSS entry, to avoid surface acne)
            bool success = randomwalk_SSS(pW, basis, rnd, subsurfaceMFP, subsurfaceAlbedo, diffuseAlbedoEntry, walk_throughput, pExit);
            if (!success)
                break;

            // Update path vertex to exit point
            pW = pExit;

            // Compute updated normal and basis at exit point
            nW = normal(pExit, MAT_SURFA);
            Basis basis_exit = makeBasis(nW);

            // Sample direction of exit ray (assuming a diffuse Lambertian lobe with diffuse albedo of exit point)
            float bsdfPdf;
            vec3 dirExitL = sampleHemisphereCosineWeighted(rnd, bsdfPdf);
            vec3 woutputW = localToWorld(dirExitL, basis_exit);

            // Update ray direction to the SSS exit direction
            rayDir = woutputW;

            // Update throughput due to random walk
            throughput *= walk_throughput;

            // Add direct lighting term at exit vertex (assumed to be a diffuse lobe)
            float skyPdf = 0.0;
            float sunPdf = 0.0;
            float sphPdf = 0.0;
            vec3 diffuseAlbedoExit = SURFACE_DIFFUSE_REFL_EVAL(pW, nW, -rayDir, rgb);
            L += throughput * SSS_exit_radiance(pExit, basis_exit, rgb, rnd, diffuseAlbedoExit,
                                                skyPdf, sunPdf, sphPdf);
            misWeightSky = powerHeuristic(bsdfPdf, skyPdf); // compute sky MIS weight for bounce ray
            misWeightSun = powerHeuristic(bsdfPdf, sunPdf); // compute sun MIS weight for bounce ray

            // Update path continuation throughput
            vec3 f = mix(vec3(1.0), diffuseAlbedoExit, subsurfaceDiffuseWeight) / M_PI;
            vec3 fOverPdf = min(vec3(radianceClamp), f/max(PDF_EPSILON, bsdfPdf));
            vec3 surface_exit_throughput = fOverPdf * abs(dot(woutputW, nW));
            throughput *= surface_exit_throughput / max(PDF_EPSILON, prob_sss);

            // Prepare for tracing the continuation ray
            pW += nW * sign(dot(rayDir, nW)) * 3.0*minLengthScale; // perturb vertex into half-space of scattered ray
        }
#endif
    }
    return L;
}

float sample_jitter(float xi)
{
    // sample from triangle filter, returning jitter in [-1, 1]
    return xi < 0.5 ? sqrt(2.0*xi) - 1.0 : 1.0 - sqrt(2.0 - 2.0*xi);
}

void pathtrace(vec2 pixel, vec4 rnd) // the current pixel
{
    float wavelength_nm = 390.0 + (750.0 - 390.0)*0.5; // non-dispersive rendering uses mid-range wavelength
    vec3 rgb = vec3(0.0);

    // Setup sun basis
    sunBasis = makeBasis(sunDir);

    // Sample radiance of primary ray
    vec3 L = vec3(0.0);
    for (int n=0; n<__MAX_SAMPLES_PER_FRAME__; ++n)
    {
        // Apply FIS to obtain pixel jitter about center in pixel units
        float jx = 0.5 * filterRadius * sample_jitter(rand(rnd));
        float jy = 0.5 * filterRadius * sample_jitter(rand(rnd));
        vec2 pixelj = pixel + vec2(jx, jy);

        // Compute world ray direction for this fragment
        vec3 primaryStart, primaryDir;
        constructPrimaryRay(pixelj, rnd, primaryStart, primaryDir);

        // Perform pathtrace to estimate the primary ray radiance, L
        L += cameraPath(primaryStart, primaryDir, wavelength_nm, rgb, rnd);
    }
    L /= float(__MAX_SAMPLES_PER_FRAME__);

    // Write updated radiance and sample count
    vec4 oldL = texture(Radiance, vTexCoord);
    float oldN = oldL.w;
    float newN = oldN + 1.0;

    // Compute tristimulus contribution from estimated radiance
    vec3 colorXYZ = rgbToXyz(L);
    vec3 newL = (oldN*oldL.rgb + colorXYZ) / newN;
    gbuf_rad = vec4(newL, newN);
    gbuf_rng = rnd;
}

void main()
{
    vec4 rnd = texture(RngData, vTexCoord);
    INIT();
    pathtrace(gl_FragCoord.xy, rnd);
}
