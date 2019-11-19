#ifndef HDRP_SPEEDTREE7_PASSES_INCLUDED
#define HDRP_SPEEDTREE7_PASSES_INCLUDED

void InitializeCommonData(inout SpeedTreeVertexInput input, float lodValue)
{
    float3 finalPosition = input.vertex.xyz;

    #ifdef ENABLE_WIND
        half windQuality = _WindQuality * _WindEnabled;

        float3 rotatedWindVector, rotatedBranchAnchor;
        if (windQuality <= WIND_QUALITY_NONE)
        {
            rotatedWindVector = float3(0.0f, 0.0f, 0.0f);
            rotatedBranchAnchor = float3(0.0f, 0.0f, 0.0f);
        }
        else
        {
            // compute rotated wind parameters
            rotatedWindVector = normalize(mul(_ST_WindVector.xyz, (float3x3)UNITY_MATRIX_M));
            rotatedBranchAnchor = normalize(mul(_ST_WindBranchAnchor.xyz, (float3x3)UNITY_MATRIX_M)) * _ST_WindBranchAnchor.w;
        }
    #endif

    #if defined(GEOM_TYPE_BRANCH) || defined(GEOM_TYPE_FROND)

        // smooth LOD
        #ifdef LOD_FADE_PERCENTAGE
            finalPosition = lerp(finalPosition, input.texcoord1.xyz, lodValue);
        #endif

        // frond wind, if needed
        #if defined(ENABLE_WIND) && defined(GEOM_TYPE_FROND)
            if (windQuality == WIND_QUALITY_PALM)
                finalPosition = RippleFrond(finalPosition, input.normal, input.texcoord.x, input.texcoord.y, input.texcoord2.x, input.texcoord2.y, input.texcoord2.z);
        #endif

    #elif defined(GEOM_TYPE_LEAF)

        // remove anchor position
        finalPosition -= input.texcoord1.xyz;

        bool isFacingLeaf = input.color.a == 0;
        if (isFacingLeaf)
        {
            #ifdef LOD_FADE_PERCENTAGE
                finalPosition *= lerp(1.0, input.texcoord1.w, lodValue);
            #endif
            // face camera-facing leaf to camera
            float offsetLen = length(finalPosition);
            float4x4 mtx_ITMV = transpose(mul(UNITY_MATRIX_I_M, unity_MatrixInvV));
            //finalPosition = mul(finalPosition.xyz, (float3x3)UNITY_MATRIX_IT_MV); // inv(MV) * finalPosition
            finalPosition = mul(mtx_ITMV, float4(finalPosition.xyz, 0)).xyz;
            finalPosition = normalize(finalPosition) * offsetLen; // make sure the offset vector is still scaled
        }
        else
        {
            #ifdef LOD_FADE_PERCENTAGE
                float3 lodPosition = float3(input.texcoord1.w, input.texcoord3.x, input.texcoord3.y);
                finalPosition = lerp(finalPosition, lodPosition, lodValue);
            #endif
        }

        #ifdef ENABLE_WIND
            // leaf wind
            if (windQuality > WIND_QUALITY_FASTEST && windQuality < WIND_QUALITY_PALM)
            {
                float leafWindTrigOffset = input.texcoord1.x + input.texcoord1.y;
                finalPosition = LeafWind(windQuality == WIND_QUALITY_BEST, input.texcoord2.w > 0.0, finalPosition, input.normal, input.texcoord2.x, float3(0,0,0), input.texcoord2.y, input.texcoord2.z, leafWindTrigOffset, rotatedWindVector);
            }
        #endif

        // move back out to anchor
        finalPosition += input.texcoord1.xyz;

    #endif

    #ifdef ENABLE_WIND
        float3 treePos = float3(UNITY_MATRIX_M[0].w, UNITY_MATRIX_M[1].w, UNITY_MATRIX_M[2].w);

        #ifndef GEOM_TYPE_MESH
            if (windQuality >= WIND_QUALITY_BETTER)
            {
                // branch wind (applies to all 3D geometry)
                finalPosition = BranchWind(windQuality == WIND_QUALITY_PALM, finalPosition, treePos, float4(input.texcoord.zw, 0, 0), rotatedWindVector, rotatedBranchAnchor);
            }
        #endif

        if (windQuality > WIND_QUALITY_NONE)
        {
            // global wind
            finalPosition = GlobalWind(finalPosition, treePos, true, rotatedWindVector, _ST_WindGlobal.x);
        }
    #endif

    input.vertex.xyz = finalPosition;
}

#include "Packages/com.unity.render-pipelines.high-definition/Runtime/RenderPipeline/ShaderPass/VertMesh.hlsl"

PackedVaryingsType SpeedTree7Vert(SpeedTreeVertexInput input)
{
    PackedVaryingsType output = (PackedVaryingsType)0;
    UNITY_SETUP_INSTANCE_ID(input);
    UNITY_TRANSFER_INSTANCE_ID(input, output.vmesh);
    UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output.vmesh);

    // handle speedtree wind and lod
    InitializeCommonData(input, unity_LODFade.x);

    float3 positionWS = TransformObjectToWorld(input.vertex.xyz);
    float3 normalWS = TransformObjectToWorldNormal(input.normal);
    float3 viewDirWS = _WorldSpaceCameraPos - positionWS;

    float4 positionCS = TransformWorldToHClip(positionWS);

#if (SHADERPASS == SHADERPASS_DEPTH_ONLY)
    positionCS.z -= _ZBias;
#endif
    
#ifdef EFFECT_BUMP
    output.vmesh.interpolators1 = normalWS;
    output.vmesh.interpolators2.xyz = TransformObjectToWorldDir(input.tangent.xyz);
#else
    output.vmesh.interpolators1 = normalWS;
    output.vmesh.interpolators2.xyz = viewDirWS;
#endif
    output.vmesh.interpolators2.w = -1.0;

    // uvHueVariation.xy as well as diffuseUV
    output.vmesh.interpolators3.xy = input.texcoord.xy;
    output.vmesh.interpolators5.rgb = _Color.rgb;
    output.vmesh.interpolators5.a = input.color.r;      // ambient occlusion factor

#if (SHADERPASS != SHADERPASS_SHADOWS) && (SHADERPASS != SHADERPASS_DEPTH_ONLY)
    // Z component of uvHueVariation
#ifdef EFFECT_HUE_VARIATION
    float4x4 objToWorld = GetRawUnityObjectToWorld();
    float hueVariationAmount = frac(objToWorld[0].w + objToWorld[1].w + objToWorld[2].w);
    hueVariationAmount += frac(input.vertex.x + input.normal.y + input.normal.x) * 0.5 - 0.3;
    output.vmesh.interpolators3.z = saturate(hueVariationAmount * _HueVariation.a);
#endif

#ifdef GEOM_TYPE_BRANCH_DETAIL
    // The two types are always in different sub-range of the mesh so no interpolation (between detail and blend) problem.
    output.vmesh.interpolators4.xy = input.texcoord2.xy;
    if (input.color.a == 0) // Blend
        output.vmesh.interpolators3.w = input.texcoord2.z;
    else // Detail texture
        output.vmesh.interpolators3.w = 2.5f; // stay out of Blend's .z range
#endif

#endif

    output.vmesh.interpolators0.xyz = positionWS;
    output.vmesh.positionCS = positionCS;

    return output;
}

PackedVaryingsType SpeedTree7VertDepth(SpeedTreeVertexInput input)
{
    PackedVaryingsType output;
    UNITY_SETUP_INSTANCE_ID(input);
    UNITY_TRANSFER_INSTANCE_ID(input, output.vmesh);
    UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output.vmesh);
    
    // handle speedtree wind and lod
    InitializeCommonData(input, unity_LODFade.x);

    float3 positionWS = TransformObjectToWorld(input.vertex.xyz);
    float4 positionCS = TransformWorldToHClip(positionWS);

    output.vmesh.interpolators3.xy = input.texcoord.xy;
    output.vmesh.interpolators0.xyz = positionWS;
    output.vmesh.positionCS = positionCS;

    return output;
}


#endif
