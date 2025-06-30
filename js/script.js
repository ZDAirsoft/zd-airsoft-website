document.addEventListener("DOMContentLoaded", () => {
  console.log("Z&D Airsoft loaded successfully!");

  // === Carousel Setup ===
  let currentIndex = 0;
  const slides = document.querySelectorAll('.carousel-slide');
  const caption = document.getElementById('carouselCaption');
  const playPauseBtn = document.getElementById('playPauseBtn');
  let playing = true;
  let interval;

  if (slides.length > 0 && caption) {
    showSlide(currentIndex);
    interval = setInterval(nextSlide, 3000);

    slides.forEach(slide => slide.addEventListener('click', togglePlay));

    const prevBtn = document.querySelector('button[onclick="prevSlide()"]');
    const nextBtn = document.querySelector('button[onclick="nextSlide()"]');
    const toggleBtn = document.querySelector('button[onclick="togglePlay()"]');

    if (prevBtn) prevBtn.addEventListener('click', prevSlide);
    if (nextBtn) nextBtn.addEventListener('click', nextSlide);
    if (toggleBtn) toggleBtn.addEventListener('click', togglePlay);
  }

  function showSlide(index) {
    slides.forEach((slide, i) => {
      slide.style.display = i === index ? 'block' : 'none';
    });
    caption.textContent = slides[index]?.alt || '';
  }

  function nextSlide() {
    currentIndex = (currentIndex + 1) % slides.length;
    showSlide(currentIndex);
  }

  function prevSlide() {
    currentIndex = (currentIndex - 1 + slides.length) % slides.length;
    showSlide(currentIndex);
  }

  function togglePlay() {
    if (!playPauseBtn) return;
    if (playing) {
      clearInterval(interval);
      playPauseBtn.textContent = '▶️';
    } else {
      interval = setInterval(nextSlide, 3000);
      playPauseBtn.textContent = '⏸️';
    }
    playing = !playing;
  }

  // === Hamburger Menu Toggle ===
  const menuToggle = document.querySelector('.menu-toggle');
  const navMenu = document.getElementById('navMenu');
  if (menuToggle && navMenu) {
    menuToggle.addEventListener('click', () => {
      navMenu.classList.toggle('active');
    });

    // Auto-close menu on link click
    const navLinks = navMenu.querySelectorAll('a');
    navLinks.forEach(link =>
      link.addEventListener('click', () => {
        navMenu.classList.remove('active');
      })
    );
  }

  // === Facebook Slideout Toggle ===
  const fbToggle = document.getElementById("fbToggle");
  const fbPanel = document.getElementById("fbFeedPanel");
  if (fbToggle && fbPanel) {
    fbToggle.addEventListener("click", () => {
      fbPanel.classList.toggle("visible");
    });
  }
});
