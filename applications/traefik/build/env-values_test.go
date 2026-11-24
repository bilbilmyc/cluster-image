package main

import (
	"encoding/json"
	"reflect"
	"testing"
)

// 从旧版手工 Helm 配置升级时，只替换本次指定的字段。
func TestMergeDeliverySettings(t *testing.T) {
	var current releaseValues
	if err := json.Unmarshal([]byte(`{
		"providers":{"kubernetesCRD":{"safeNaming":true}},
		"ports":{"web":{"http":{"middlewares":["auth@file","traefik-global-cors@kubernetescrd"]}}},
		"additionalArguments":["--log.format=json","--serversTransport.forwardingTimeouts.dialTimeout=8s",
			"--SERVERSTRANSPORT.FORWARDINGTIMEOUTS.RESPONSEHEADERTIMEOUT","30s",
			"--entryPoints.web.transport.respondingTimeouts.writeTimeout=40s"]
	}`), &current); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TRAEFIK_REQUEST_TIMEOUT", "7200s")
	t.Setenv("TRAEFIK_WRITE_TIMEOUT", "0s")
	t.Setenv("TRAEFIK_GLOBAL_CORS", "true")
	patch, err := overrides(current)
	if err != nil {
		t.Fatal(err)
	}
	args := []string{"--log.format=json", "--serversTransport.forwardingTimeouts.dialTimeout=8s",
		"--serversTransport.forwardingTimeouts.responseHeaderTimeout=7200s"}
	if !reflect.DeepEqual(patch["additionalArguments"], args) {
		t.Fatalf("附加参数有误 / unexpected arguments: %v", patch)
	}
	ports := patch["ports"].(map[string]any)
	for _, entry := range []string{"web", "websecure"} {
		port := ports[entry].(map[string]any)
		expected := map[string]string{"readTimeout": "7200s", "writeTimeout": "0s"}
		if !reflect.DeepEqual(port["transport"].(map[string]any)["respondingTimeouts"], expected) {
			t.Fatalf("入口超时有误 / unexpected timeouts: %v", port)
		}
		expectedChain := []string{"traefik_global-cors@kubernetescrd"}
		if entry == "web" {
			expectedChain = append(expectedChain, "auth@file")
		}
		if !reflect.DeepEqual(port["http"].(map[string]any)["middlewares"], expectedChain) {
			t.Fatalf("中间件链有误 / unexpected middleware chain: %v", port)
		}
	}
}

// 空参数不覆盖已有值，非法时长不能进入 Helm 升级。
func TestEmptyAndInvalidSettings(t *testing.T) {
	patch, err := overrides(releaseValues{AdditionalArguments: []string{"--log.format=json"}})
	if err != nil || len(patch) != 0 {
		t.Fatalf("空参数应保留配置 / expected empty overrides: %v %v", patch, err)
	}
	for _, input := range []string{"-1s", "7200ss", "unlimited"} {
		t.Setenv("TRAEFIK_REQUEST_TIMEOUT", input)
		if _, err := overrides(releaseValues{}); err == nil {
			t.Fatalf("应拒绝非法时长 / invalid duration accepted: %s", input)
		}
	}
}
