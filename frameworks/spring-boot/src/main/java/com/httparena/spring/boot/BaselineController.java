package com.httparena.spring.boot;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/baseline11")
public class BaselineController {
    @GetMapping
    public String baseline(@RequestParam("a") int a, @RequestParam("b") int b) {
        return String.valueOf(a + b);
    }

    @PostMapping
    public String baselinePost(@RequestParam("a") int a, @RequestParam("b") int b, @RequestBody String body) {
        int bodyNumber = Integer.parseInt(body);
        return String.valueOf(a + b + bodyNumber);
    }
}
