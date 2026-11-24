// 将交付环境变量合并为 Helm 覆盖值，只输出显式调整的字段。
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"strings"
	"time"
)

type releaseValues struct {
	Ports map[string]struct {
		HTTP struct{ Middlewares []string }
	}
	Providers struct {
		KubernetesCRD struct{ SafeNaming bool }
	}
	AdditionalArguments []string
}

func durationValue(name, fallback string) (string, error) {
	value := os.Getenv(name)
	if value == "" {
		return fallback, nil
	}
	if strings.Trim(value, "0123456789") == "" {
		value += "s"
	}
	duration, err := time.ParseDuration(value)
	if err != nil || duration < 0 {
		return "", fmt.Errorf("%s 需要非负时长 / expected a non-negative duration, e.g. 7200s", name)
	}
	return value, nil
}

// 同时识别等号写法和独立参数值，保留所有无关参数的原始顺序。
func takeFlag(args []string, flag string) (rest, values []string) {
	rest = make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		key, value, hasValue := strings.Cut(args[i], "=")
		if !strings.EqualFold(key, flag) {
			rest = append(rest, args[i])
			continue
		}
		if !hasValue && i+1 < len(args) && !strings.HasPrefix(args[i+1], "--") {
			i++
			value = args[i]
		}
		values = append(values, value)
	}
	return rest, values
}

func middlewareChain(existing, flags []string, enabled, safeNaming bool) []string {
	const legacy = "traefik-global-cors@kubernetescrd"
	const safe = "traefik_global-cors@kubernetescrd"
	chain := []string{}
	if enabled {
		ref := legacy
		if safeNaming {
			ref = safe
		}
		chain = append(chain, ref)
	}
	for _, ref := range existing {
		if ref != legacy && ref != safe {
			chain = append(chain, ref)
		}
	}
	for _, flag := range flags {
		for _, ref := range strings.Split(flag, ",") {
			ref = strings.TrimSpace(ref)
			if ref != "" && ref != legacy && ref != safe && !slices.Contains(chain, ref) {
				chain = append(chain, ref)
			}
		}
	}
	return chain
}

func overrides(current releaseValues) (map[string]any, error) {
	request, err := durationValue("TRAEFIK_REQUEST_TIMEOUT", "")
	if err != nil {
		return nil, err
	}
	cors := os.Getenv("TRAEFIK_GLOBAL_CORS")
	if cors != "" && cors != "true" && cors != "false" {
		return nil, fmt.Errorf("TRAEFIK_GLOBAL_CORS 仅接受 true 或 false / expected true or false")
	}

	patch := map[string]any{}
	args := current.AdditionalArguments
	incoming := map[string]string{}
	for _, setting := range []struct{ name, key, fallback string }{
		{"TRAEFIK_READ_TIMEOUT", "readTimeout", request},
		{"TRAEFIK_WRITE_TIMEOUT", "writeTimeout", request},
		{"TRAEFIK_IDLE_TIMEOUT", "idleTimeout", ""},
	} {
		value, err := durationValue(setting.name, setting.fallback)
		if err != nil {
			return nil, err
		}
		if value != "" {
			incoming[setting.key] = value
		}
	}

	if len(incoming) > 0 || cors != "" {
		ports := map[string]any{}
		safe := current.Providers.KubernetesCRD.SafeNaming
		_, naming := takeFlag(args, "--providers.kubernetescrd.safenaming")
		if len(naming) > 0 {
			safe = naming[len(naming)-1] == "" || strings.EqualFold(naming[len(naming)-1], "true")
		}
		for _, entry := range []string{"web", "websecure"} {
			port := map[string]any{}
			prefix := "--entryPoints." + entry
			if len(incoming) > 0 {
				port["transport"] = map[string]any{"respondingTimeouts": incoming}
				for key := range incoming {
					args, _ = takeFlag(args, prefix+".transport.respondingTimeouts."+key)
				}
			}
			if cors != "" {
				var flags []string
				args, flags = takeFlag(args, prefix+".http.middlewares")
				chain := middlewareChain(current.Ports[entry].HTTP.Middlewares, flags, cors == "true", safe)
				port["http"] = map[string]any{"middlewares": chain}
			}
			ports[entry] = port
		}
		patch["ports"] = ports
	}

	// 此 Chart 版本通过附加启动参数设置默认后端连接的三项时限。
	for _, setting := range []struct{ name, key, fallback string }{
		{"TRAEFIK_DIAL_TIMEOUT", "dialTimeout", ""},
		{"TRAEFIK_RESPONSE_HEADER_TIMEOUT", "responseHeaderTimeout", request},
		{"TRAEFIK_IDLE_CONN_TIMEOUT", "idleConnTimeout", ""},
	} {
		value, err := durationValue(setting.name, setting.fallback)
		if err != nil {
			return nil, err
		}
		if value != "" {
			flag := "--serversTransport.forwardingTimeouts." + setting.key
			args, _ = takeFlag(args, flag)
			args = append(args, flag+"="+value)
		}
	}
	if !slices.Equal(args, current.AdditionalArguments) {
		patch["additionalArguments"] = args
	}
	return patch, nil
}

func main() {
	var current releaseValues
	err := json.NewDecoder(os.Stdin).Decode(&current)
	if err == nil {
		var patch map[string]any
		patch, err = overrides(current)
		if err == nil {
			err = json.NewEncoder(os.Stdout).Encode(patch)
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "生成交付配置失败 / Failed to render deployment values:", err)
		os.Exit(1)
	}
}
