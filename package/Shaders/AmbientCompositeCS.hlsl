#include "Common/Color.hlsli"
#include "Common/FrameBuffer.hlsli"
#include "Common/GBuffer.hlsli"
#include "Common/Math.hlsli"
#include "Common/SharedData.hlsli"
#include "Common/VR.hlsli"

Texture2D<unorm half3> AlbedoTexture : register(t0);
Texture2D<unorm half3> NormalRoughnessTexture : register(t1);

#if defined(SKYLIGHTING)
#	include "Skylighting/Skylighting.hlsli"

Texture2D<unorm float> DepthTexture : register(t2);
Texture3D<sh2> SkylightingProbeArray : register(t3);
#endif

#if defined(SSGI)
Texture2D<half4> SSGITexture : register(t4);
#endif

Texture2D<unorm half3> Masks2Texture : register(t5);

RWTexture2D<half3> MainRW : register(u0);
#if defined(SSGI)
RWTexture2D<half3> DiffuseAmbientRW : register(u1);
#endif

[numthreads(8, 8, 1)] void main(uint3 dispatchID
								: SV_DispatchThreadID) {
	half2 uv = half2(dispatchID.xy + 0.5) * BufferDim.zw * DynamicResolutionParams2.xy;
	uint eyeIndex = Stereo::GetEyeIndexFromTexCoord(uv);
	uv = Stereo::ConvertFromStereoUV(uv, eyeIndex);

	half3 normalGlossiness = NormalRoughnessTexture[dispatchID.xy];
	half3 normalVS = GBuffer::DecodeNormal(normalGlossiness.xy);

	half3 diffuseColor = MainRW[dispatchID.xy];
	half3 albedo = AlbedoTexture[dispatchID.xy];
	half3 masks2 = Masks2Texture[dispatchID.xy];

	half pbrWeight = masks2.z;

	half3 normalWS = normalize(mul(CameraViewInverse[eyeIndex], half4(normalVS, 0)).xyz);

	half3 directionalAmbientColor = mul(DirectionalAmbientShared, half4(normalWS, 1.0));

	half3 linAlbedo = Color::GammaToLinear(albedo) / Color::AlbedoPreMult;
	half3 linDirectionalAmbientColor = Color::GammaToLinear(directionalAmbientColor) / Color::LightPreMult;
	half3 linDiffuseColor = Color::GammaToLinear(diffuseColor);

	half3 linAmbient = lerp(Color::GammaToLinear(albedo * directionalAmbientColor), linAlbedo * linDirectionalAmbientColor, pbrWeight);

	half visibility = 1.0;
#if defined(SKYLIGHTING)
	float rawDepth = DepthTexture[dispatchID.xy];
	float4 positionCS = float4(2 * float2(uv.x, -uv.y + 1) - 1, rawDepth, 1);
	float4 positionMS = mul(CameraViewProjInverse[eyeIndex], positionCS);
	positionMS.xyz = positionMS.xyz / positionMS.w;
#	if defined(VR)
	positionMS.xyz += CameraPosAdjust[eyeIndex] - CameraPosAdjust[0];
#	endif

	sh2 skylighting = Skylighting::sample(skylightingSettings, SkylightingProbeArray, positionMS.xyz, normalWS);
	half skylightingDiffuse = shFuncProductIntegral(skylighting, shEvaluateCosineLobe(float3(normalWS.xy, normalWS.z * 0.5 + 0.5))) / Math::PI;
	skylightingDiffuse = Skylighting::mixDiffuse(skylightingSettings, skylightingDiffuse);

	visibility = skylightingDiffuse;
#endif

#if defined(SSGI)
	half4 ssgiDiffuse = SSGITexture[dispatchID.xy];
	ssgiDiffuse.rgb *= linAlbedo;
	ssgiDiffuse.a = 1 - ssgiDiffuse.a;

	visibility *= ssgiDiffuse.a;

	DiffuseAmbientRW[dispatchID.xy] = linAlbedo * linDirectionalAmbientColor + ssgiDiffuse.rgb;

#	if defined(INTERIOR)
	linDiffuseColor *= ssgiDiffuse.a;
#	endif
	linDiffuseColor += ssgiDiffuse.rgb;
#endif

	linAmbient *= visibility;
	diffuseColor = Color::LinearToGamma(linDiffuseColor);
	directionalAmbientColor = Color::LinearToGamma(linDirectionalAmbientColor * visibility * Color::LightPreMult);

	diffuseColor = lerp(diffuseColor + directionalAmbientColor * albedo, Color::LinearToGamma(linDiffuseColor + linAmbient), pbrWeight);

	MainRW[dispatchID.xy] = diffuseColor;
};